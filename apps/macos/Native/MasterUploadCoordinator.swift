import Foundation
import TrigoContracts

/// A separate, application-owned scheduler. Durable media cursors are the producer boundary;
/// no recording callback waits for networking and no view owns a request's lifetime.
public actor MasterUploadCoordinator {
  private let repository: LocalRepository
  private let transport: any MasterUploadTransport
  private let interval: Duration
  private let interruption: MasterUploadInterruption
  private var worker: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var events: AsyncStream<Void>.Continuation?
  private var retryCorrections = false
  private var runningPass = false

  public init(
    repository: LocalRepository,
    transport: any MasterUploadTransport,
    interval: Duration = .seconds(5),
    interruption: @escaping MasterUploadInterruption = { _ in }
  ) {
    self.repository = repository
    self.transport = transport
    self.interval = max(interval, .milliseconds(10))
    self.interruption = interruption
  }

  public func start() {
    guard worker == nil else { wake(); return }
    let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    events = stream.continuation
    worker = Task { [weak self] in
      for await _ in stream.stream {
        guard !Task.isCancelled, let self else { break }
        await self.consumeEvent()
      }
    }
    let interval = interval
    timer = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { break }
        await self?.wake(retryAfterCorrection: false)
      }
    }
    wake()
  }

  /// Explicit wake follows a repaired connection or app wake; periodic polls do not retry
  /// failures whose durable classification requires a correction.
  public func wake(retryAfterCorrection: Bool = true) {
    retryCorrections = retryCorrections || retryAfterCorrection
    events?.yield(())
  }

  public func stop() async {
    timer?.cancel()
    timer = nil
    let current = worker
    worker = nil
    events?.finish()
    events = nil
    current?.cancel()
    await current?.value
  }

  private func consumeEvent() async {
    let retry = retryCorrections
    retryCorrections = false
    _ = try? await runPass(retryAfterCorrection: retry)
  }

  /// Deterministic foreground seam for recovery/tests; concurrent requests coalesce.
  public func runPass(retryAfterCorrection: Bool = true) async throws -> MasterUploadPassReport {
    var report = MasterUploadPassReport()
    guard !runningPass else { report.coalesced = true; return report }
    runningPass = true
    defer { runningPass = false }
    var after: String?
    while true {
      try Task.checkCancellation()
      let calls = try await repository.calls(after: after)
      for call in calls {
        try Task.checkCancellation()
        do {
          guard let state = try await repository.lifecycle(callID: call.callID),
            state.deletion.state == .active,
            let session = try await repository.captureSession(callID: call.callID)
          else { continue }
          // Cleanup is local recovery work and remains available while authentication is blocked.
          if try repository.verifiedMasterReceipt(callID: call.callID) != nil {
            if try repository.masterUpload(callID: call.callID)?.cleanupComplete == false {
              try await repository.cleanupVerifiedMaster(
                callID: call.callID,
                interruption: interruption
              )
              report.cleanedCallIDs.append(call.callID)
            }
            continue
          }
          if let failure = state.upload.failure,
            failure.retry == .never || (failure.retry == .afterCorrection && !retryAfterCorrection)
          {
            continue
          }
          try await upload(session, report: &report)
        } catch is CancellationError { throw CancellationError() } catch {
          let failure = try failure(for: error)
          report.failures[call.callID] = failure
          await persistFailure(failure, callID: call.callID)
        }
      }
      if calls.count < 100 { return report }
      after = calls.last?.callID
    }
  }

  private func upload(
    _ session: CaptureArchiveSession,
    report: inout MasterUploadPassReport
  ) async throws {
    let callID = session.callID
    let state = try await repository.ensureMasterUpload(session)
    let completion = try repository.captureCompletion(callID: callID)
    guard let cursor = try repository.confirmedMediaCursor(callID: callID) else {
      if completion != nil {
        throw MasterUploadError.transport(code: "upload_media_missing", retry: .afterCorrection)
      }
      return
    }
    try await repository.markRunning(state.operationID)
    _ = try await repository.updateLifecycle(callID: callID) { lifecycle in
      guard lifecycle.deletion.state == .active else { throw MasterUploadError.fenced }
      lifecycle.upload = .init(state: .uploading)
    }
    if !state.registered {
      let request = try await repository.masterUploadRegistration(callID: callID)
      let receipt = try await transport.register(request)
      try Task.checkCancellation()
      try await repository.acceptMasterUploadSession(receipt, callID: callID)
    }
    let finalized = completion?.master != nil
    let partBytes = MediaMasterProfile.maximumRequestBytes
    let stableBytes = Int(cursor.stableBytes)
    let count = finalized ? (stableBytes + partBytes - 1) / partBytes : stableBytes / partBytes
    let previous = try repository.masterUploadParts(callID: callID)
    var uploaded = 0
    for index in 0..<count {
      if previous.contains(where: { $0.descriptor.index == index && $0.receipt != nil }) {
        continue
      }
      // A finite turn bounds work per call, so an old backlog cannot starve newer captures.
      guard uploaded < 4 else { return }
      try Task.checkCancellation()
      let offset = index * partBytes
      let length = min(partBytes, stableBytes - offset)
      let bytes = try RecoverableMediaMaster.readStableBytes(
        directory: session.mediaDirectory,
        confirmed: cursor,
        in: Int64(offset)..<Int64(offset + length)
      )
      let part = UploadPartDescriptor(
        index: index,
        byteOffset: offset,
        byteLength: length,
        sha256: Contract.hash(bytes)
      )
      try repository.prepareMasterUploadPart(callID: callID, descriptor: part)
      let receipt = try await transport.upload(
        callID: callID,
        uploadID: state.uploadID,
        part: part,
        bytes: bytes
      )
      try Task.checkCancellation()
      try await repository.acceptMasterUploadPart(receipt, callID: callID)
      uploaded += 1
      report.uploadedParts += 1
    }
    guard finalized else { return }
    try Task.checkCancellation()
    let request = try await repository.prepareMasterFinalization(callID: callID)
    try await repository.markRunning(state.finalizeOperationID)
    let receipt = try await transport.finalize(callID: callID, request: request)
    try Task.checkCancellation()
    try await repository.acceptVerifiedMasterReceipt(
      receipt,
      callID: callID,
      interruption: interruption
    )
    report.storedCallIDs.append(callID)
    try await repository.cleanupVerifiedMaster(callID: callID, interruption: interruption)
    report.cleanedCallIDs.append(callID)
  }

  private func persistFailure(_ failure: LifecycleFailure, callID: String) async {
    // A post-commit cleanup fault must never downgrade an already verified stored master.
    guard (try? repository.verifiedMasterReceipt(callID: callID)) == nil else { return }
    _ = try? await repository.updateLifecycle(callID: callID) { lifecycle in
      guard lifecycle.deletion.state == .active else { throw MasterUploadError.fenced }
      lifecycle.upload = .init(state: .failed, failure: failure)
    }
    guard let state = try? repository.masterUpload(callID: callID) else { return }
    for id in [state.operationID, state.finalizeOperationID]
    where (try? await repository.operation(id)) != nil {
      if failure.retry == .afterCorrection {
        _ = try? await repository.markBlocked(id, failure: failure)
      } else {
        _ = try? await repository.markFailed(id, failure: failure)
      }
    }
  }

  private func failure(for error: any Error) throws -> LifecycleFailure {
    switch error {
    case MasterUploadError.transport(let code, let retry): try .init(code: code, retry: retry)
    case MasterUploadError.remoteBlocked:
      try .init(code: "upload_connection_blocked", retry: .afterCorrection)
    case MasterUploadError.fenced: try .init(code: "upload_deletion_fenced", retry: .never)
    case MasterUploadError.invalidReceipt:
      try .init(code: "upload_receipt_invalid", retry: .afterCorrection)
    case MasterUploadError.invalidPart:
      try .init(code: "upload_part_invalid", retry: .afterCorrection)
    default: try .init(code: "upload_local_failure", retry: .afterCorrection)
    }
  }
}
