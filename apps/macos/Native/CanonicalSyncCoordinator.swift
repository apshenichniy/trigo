import Foundation
import TrigoContracts

/// The application owns this worker. A view may wake it, but cannot cancel an admitted
/// import/publication by closing. Durable cursors, immutable intents and SQLite commits
/// are the recovery boundary; a timer is only a hint to inspect that work again.
public actor CanonicalSyncCoordinator {
  let repository: LocalRepository
  let transport: any CanonicalSyncTransport
  private let language: @Sendable () async -> String
  private let interval: Duration
  private let onChange: @Sendable () async -> Void
  private var worker: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var events: AsyncStream<Void>.Continuation?
  private var runningPass = false
  private var presentedVersion: [Int]?
  private var retryAllCorrections = false
  private var correctedCalls: Set<String> = []

  public init(
    repository: LocalRepository,
    transport: any CanonicalSyncTransport,
    language: @escaping @Sendable () async -> String = { "ru" },
    interval: Duration = .seconds(5),
    onChange: @escaping @Sendable () async -> Void = {}
  ) {
    self.repository = repository
    self.transport = transport
    self.language = language
    self.interval = max(interval, .milliseconds(10))
    self.onChange = onChange
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

  public func wake(retryAfterCorrection: Bool = true, callID: String? = nil) {
    if retryAfterCorrection {
      if let callID { correctedCalls.insert(callID) } else { retryAllCorrections = true }
    }
    events?.yield(())
  }

  private func consumeEvent() async {
    let retry = retryAllCorrections
    let corrected = correctedCalls
    retryAllCorrections = false
    correctedCalls = []
    let report = try? await runPass(retryAfterCorrection: retry, correctedCallIDs: corrected)
    let version = try? repository.presentationVersion()
    if report?.didChange == true || presentedVersion != version {
      presentedVersion = version
      await onChange()
    }
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

  public func runPass(
    retryAfterCorrection: Bool = true,
    correctedCallIDs: Set<String> = []
  ) async throws -> CanonicalSyncPassReport {
    var report = CanonicalSyncPassReport()
    guard !runningPass else { report.coalesced = true; return report }
    runningPass = true
    defer { runningPass = false }
    try await repository.upgradeLegacyCallSnapshots()
    do { try await retainRemoteChanges(report: &report) } catch is CancellationError {
      throw CancellationError()
    } catch { report.catalogFailure = try syncFailure(error) }
    if let failure = report.catalogFailure { try repository.recordSynchronizationStatus(failure) }

    // Entries without a local call are retried from durable catalog work even when the
    // change stream is quiet. One broken call does not strand every other entry's cursor.
    if report.catalogFailure == nil {
      var after = ""
      while true {
        let entries = try repository.serverCatalogEntries(after: after)
        for entry in entries where entry.deletion == nil {
          try Task.checkCancellation()
          do {
            if try repository.currentHash(entry.callId) == nil {
              guard let reference = entry.replica, let receipt = entry.audio else {
                throw CanonicalSyncError.missingCanonicalDocument
              }
              let contents = try await downloadReplica(
                callID: entry.callId,
                reference: reference,
                receipt: receipt
              )
              _ = try await repository.restoreReplica(contents)
              report.restoredCallIDs.append(entry.callId)
              report.didChange = true
            }
          } catch is CancellationError { throw CancellationError() } catch {
            report.failures[entry.callId] = try syncFailure(error)
          }
        }
        if entries.count < 100 { break }
        after = entries.last!.callId
      }
      try repository.recordSynchronizationStatus(
        report.failures.sorted(by: { $0.key < $1.key }).first?.value
      )
    }

    var after: String?
    while true {
      let calls = try await repository.calls(after: after)
      for call in calls {
        try Task.checkCancellation()
        do {
          if let failure = report.catalogFailure {
            try await repository.ensureCanonicalReplica(callID: call.callID)
            await persistSyncFailure(failure, callID: call.callID, report: &report)
            continue
          }
          try await synchronizeCall(
            call.callID,
            retryAfterCorrection: retryAfterCorrection || correctedCallIDs.contains(call.callID),
            report: &report
          )
        } catch is CancellationError { throw CancellationError() } catch {
          let failure = try syncFailure(error)
          report.failures[call.callID] = failure
          await persistSyncFailure(failure, callID: call.callID, report: &report)
        }
      }
      if calls.count < 100 { return report }
      after = calls.last!.callID
    }
  }

  private func retainRemoteChanges(report: inout CanonicalSyncPassReport) async throws {
    if let cursor = try repository.syncCursor() {
      do { try await retainChanges(from: cursor, report: &report); return } catch CanonicalSyncError
        .cursorReset
      { /* Reconcile into the existing archive. */  }
    }
    var cursor: String?
    var watermark: String?
    var previousCall = ""
    var seenCursors = Set<String>()
    repeat {
      try Task.checkCancellation()
      let page = try await transport.catalog(cursor: cursor)
      guard page.archiveId == repository.archiveID, page.calls.count <= 100,
        watermark == nil || watermark == page.changesCursor
      else { throw CanonicalSyncError.invalidResult }
      watermark = page.changesCursor
      for entry in page.calls {
        guard entry.callId > previousCall else { throw CanonicalSyncError.invalidResult }
        try await repository.retainCatalogEntry(entry)
        if entry.deletion != nil { report.didChange = true }
        previousCall = entry.callId
      }
      cursor = page.nextCursor
      if let cursor, !seenCursors.insert(cursor).inserted { throw CanonicalSyncError.invalidResult }
    } while cursor != nil
    guard let watermark else { throw CanonicalSyncError.invalidResult }
    try repository.advanceSyncCursor(watermark)
    try await retainChanges(from: watermark, report: &report)
  }

  private func retainChanges(
    from initial: String,
    report: inout CanonicalSyncPassReport
  ) async throws {
    var cursor = initial
    var seenCursors: Set<String> = [initial]
    var sequence = 0
    while true {
      try Task.checkCancellation()
      let page = try await transport.changes(cursor: cursor)
      guard page.archiveId == repository.archiveID, page.changes.count <= 100 else {
        throw CanonicalSyncError.invalidResult
      }
      for change in page.changes {
        guard change.sequence > sequence else { throw CanonicalSyncError.invalidResult }
        try await repository.retainCatalogEntry(change.call)
        if change.call.deletion != nil { report.didChange = true }
        sequence = change.sequence
      }
      if page.hasMore, !seenCursors.insert(page.nextCursor).inserted {
        throw CanonicalSyncError.invalidResult
      }
      try repository.advanceSyncCursor(page.nextCursor)
      if !page.hasMore { return }
      cursor = page.nextCursor
    }
  }

  private func synchronizeCall(
    _ callID: String,
    retryAfterCorrection: Bool,
    report: inout CanonicalSyncPassReport
  ) async throws {
    let entry = try repository.serverCatalogEntry(callID: callID)
    if let reference = entry?.replica, let receipt = entry?.audio,
      try repository.observedReplica(callID: callID)?.version ?? 0 < reference.documentVersion
    {
      let contents = try await downloadReplica(
        callID: callID,
        reference: reference,
        receipt: receipt
      )
      _ = try await repository.reconcileServerReplica(contents)
      report.didChange = true
    }
    let call = try await repository.call(callID: callID)
    guard call.captureState != "recording",
      try repository.verifiedMasterReceipt(callID: callID) != nil
    else { return }
    try await repository.ensureCanonicalReplica(callID: callID)
    try await publishPending(
      callID: callID,
      retryAfterCorrection: retryAfterCorrection,
      report: &report
    )
    let resultAvailable: Bool
    do {
      resultAvailable = try await synchronizeTranscription(
        callID: callID,
        entry: entry,
        retryAfterCorrection: retryAfterCorrection,
        report: &report
      )
    } catch is CancellationError { throw CancellationError() } catch {
      let failure = try syncFailure(error)
      _ = try? await repository.updateLifecycle(callID: callID) { lifecycle in
        guard lifecycle.deletion.state == .active else { throw CanonicalSyncError.deleted }
        lifecycle.transcription.failure = failure
      }
      report.didChange = true
      throw error
    }
    let importedCount = try repository.importedServerResultCount(callID: callID)
    if resultAvailable || (entry?.resultCount ?? 0) > importedCount {
      if let failure = try await repository.lifecycle(callID: callID)?.importState.failure,
        failure.retry == .never || failure.retry == .afterCorrection && !retryAfterCorrection
      {
        return
      }
      do {
        for result in try await allResults(callID: callID) {
          if try repository.isServerResultImported(revisionID: result.result.revisionId) {
            continue
          }
          let evidence = try await downloadResult(result, callID: callID)
          do {
            _ = try await repository.importAvailableResult(
              result,
              callID: callID,
              revision: evidence.revision,
              provenance: evidence.provenance
            )
          } catch LocalPersistenceError.concurrentMutation {
            // A local edit may land during the download. Reprepare against its committed
            // snapshot once; the next application pass resumes sustained contention.
            _ = try await repository.importAvailableResult(
              result,
              callID: callID,
              revision: evidence.revision,
              provenance: evidence.provenance
            )
          }
          report.importedRevisionIDs.append(result.result.revisionId)
          report.didChange = true
        }
      } catch is CancellationError { throw CancellationError() } catch {
        let failure = try syncFailure(error)
        _ = try? await repository.updateLifecycle(callID: callID) { lifecycle in
          guard lifecycle.deletion.state == .active else { throw CanonicalSyncError.deleted }
          lifecycle.importState = .init(state: .failed, failure: failure)
        }
        report.didChange = true
        throw error
      }
      try await publishPending(
        callID: callID,
        retryAfterCorrection: retryAfterCorrection,
        report: &report
      )
    }
  }

  private func publishPending(
    callID: String,
    retryAfterCorrection: Bool,
    report: inout CanonicalSyncPassReport
  ) async throws {
    if try await repository.lifecycle(callID: callID)?.replica.state == .conflict {
      if !report.conflictCallIDs.contains(callID) { report.conflictCallIDs.append(callID) }
      return
    }
    if let failure = try await repository.lifecycle(callID: callID)?.replica.failure,
      failure.retry == .never || failure.retry == .afterCorrection && !retryAfterCorrection
    {
      return
    }
    for work in try repository.pendingReplicas(callID: callID).prefix(4) {
      try Task.checkCancellation()
      let request = try await repository.bindReplicaRequest(operationID: work.operationID)
      do {
        let receipt = try await transport.publish(callID: callID, request: request)
        try Task.checkCancellation()
        try await repository.acceptReplicaReceipt(receipt)
        report.publishedCallIDs.append(callID)
        report.didChange = true
      } catch CanonicalSyncError.conflict {
        guard let receipt = try repository.verifiedMasterReceipt(callID: callID)?.value else {
          throw CanonicalSyncError.invalidReceipt
        }
        let contents = try await downloadReplica(callID: callID, reference: nil, receipt: receipt)
        try await repository.recordReplicaConflict(contents)
        if try await repository.lifecycle(callID: callID)?.replica.state == .conflict {
          report.conflictCallIDs.append(callID)
        }
        report.didChange = true
        return
      }
    }
  }

  private func synchronizeTranscription(
    callID: String,
    entry: CallCatalogEntry?,
    retryAfterCorrection: Bool,
    report: inout CanonicalSyncPassReport
  ) async throws -> Bool {
    if let failure = try await repository.lifecycle(callID: callID)?.transcription.failure,
      failure.code.hasPrefix("sync_"),
      failure.retry == .never || failure.retry == .afterCorrection && !retryAfterCorrection
    {
      return false
    }
    var automatic = try repository.automaticTranscription(callID: callID)
    let refresh = try repository.catalogOperationNeedsRefresh(callID: callID)
    if let operationID = entry?.latestTranscriptionOperationId,
      automatic?.request.operationId != operationID
    {
      let previous = try repository.observedTranscription(callID: callID)
      let operation: TranscriptionOperation
      if let previous, previous.operationId == operationID,
        previous.state == "result_available" || previous.state == "failed", !refresh
      {
        operation = previous
      } else {
        operation = try await transport.operation(operationID: operationID)
      }
      guard operation.operationId == operationID else { throw CanonicalSyncError.invalidResult }
      try await repository.acceptTranscriptionOperation(operation, callID: callID)
      try repository.acknowledgeCatalogOperation(callID: callID, operationID: operationID)
      report.didChange = report.didChange || previous != operation
      return try operation.result != nil
        && !repository.isServerResultImported(revisionID: operation.revisionId)
    }
    if automatic == nil {
      automatic = try await repository.ensureAutomaticTranscription(
        callID: callID,
        language: language()
      )
    }
    guard let automatic else { return false }
    let operation: TranscriptionOperation
    if automatic.operation == nil || automatic.recoveryPending {
      operation = try await transport.requestTranscription(
        callID: callID,
        request: automatic.request
      )
      guard operation.operationId == automatic.request.operationId,
        operation.revisionId == automatic.request.revisionId
      else { throw CanonicalSyncError.invalidResult }
      try await repository.acceptTranscriptionOperation(operation, callID: callID)
      if automatic.recoveryPending {
        try repository.acknowledgeTranscriptionRecovery(callID: callID)
      }
    } else if let retained = automatic.operation, !refresh,
      retained.state == "result_available"
        || retained.state == "failed" && retained.failure?.code != "asr_workflow_interrupted"
    {
      operation = retained
    } else {
      let observed = try await transport.operation(operationID: automatic.request.operationId)
      guard observed.operationId == automatic.request.operationId,
        observed.revisionId == automatic.request.revisionId
      else { throw CanonicalSyncError.invalidResult }
      let canResumeWait =
        ["asr_workflow_interrupted", "asr_processing_timeout"]
        .contains(observed.failure?.code ?? "")
        || (retryAfterCorrection && observed.failure?.code == "asr_admission_uncertain")
      if observed.state != "result_available", canResumeWait,
        !automatic.recoveryAttempted || retryAfterCorrection,
        try repository.reserveTranscriptionRecovery(
          callID: callID,
          afterCorrection: retryAfterCorrection
        )
      {
        operation = try await transport.requestTranscription(
          callID: callID,
          request: automatic.request
        )
        guard operation.operationId == automatic.request.operationId,
          operation.revisionId == automatic.request.revisionId
        else { throw CanonicalSyncError.invalidResult }
        try await repository.acceptTranscriptionOperation(operation, callID: callID)
        try repository.acknowledgeTranscriptionRecovery(callID: callID)
      } else {
        operation = observed
        if automatic.operation != operation {
          try await repository.acceptTranscriptionOperation(operation, callID: callID)
        }
      }
    }
    if automatic.operation != operation {
      report.changedOperationIDs.append(operation.operationId)
      report.didChange = true
    }
    try repository.acknowledgeCatalogOperation(callID: callID, operationID: operation.operationId)
    return try operation.result != nil
      && !repository.isServerResultImported(revisionID: operation.revisionId)
  }

  private func persistSyncFailure(
    _ failure: LifecycleFailure,
    callID: String,
    report: inout CanonicalSyncPassReport
  ) async {
    guard let pending = try? repository.pendingReplicas(callID: callID), !pending.isEmpty,
      let state = try? await repository.lifecycle(callID: callID), state.replica.state != .conflict,
      state.replica.failure != failure
    else { return }
    _ = try? await repository.updateLifecycle(callID: callID) { lifecycle in
      guard lifecycle.deletion.state == .active, lifecycle.replica.state != .conflict else {
        throw CanonicalSyncError.deleted
      }
      lifecycle.replica = .init(state: .pending, failure: failure)
    }
    report.didChange = true
  }

  private func syncFailure(_ error: any Error) throws -> LifecycleFailure {
    switch error {
    case CanonicalSyncError.remote(let code, let retry):
      try .init(
        code: isStableFailureCode(code) ? code : "sync_incompatible_document",
        retry: isStableFailureCode(code) ? retry : .afterCorrection
      )
    case CanonicalSyncError.deleted: try .init(code: "call_deleted", retry: .never)
    case CanonicalSyncError.conflict: try .init(code: "sync_conflict", retry: .afterCorrection)
    case CanonicalSyncError.unauthorized:
      try .init(code: "sync_connection_blocked", retry: .afterCorrection)
    case CanonicalSyncError.serverUnavailable:
      try .init(code: "sync_server_unavailable", retry: .retryable)
    case CanonicalSyncError.missingCanonicalDocument:
      try .init(code: "sync_metadata_unavailable", retry: .afterCorrection)
    case CanonicalSyncError.incompatibleDocument:
      try .init(code: "sync_incompatible_document", retry: .afterCorrection)
    case CanonicalSyncError.invalidReceipt, CanonicalSyncError.invalidResult, is ContractError:
      try .init(code: "sync_evidence_invalid", retry: .afterCorrection)
    default: try .init(code: "sync_local_failure", retry: .afterCorrection)
    }
  }
}
