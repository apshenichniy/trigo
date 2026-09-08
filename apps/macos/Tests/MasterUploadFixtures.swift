import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

struct MasterUploadFixture {
  let root: URL
  let session: CaptureArchiveSession
  let repository: LocalRepository
  let writer: RecoverableMediaMaster

  static func create(seconds: Int = 1) async throws -> Self {
    let root = repositoryRoot("upload")
    let session = try repositorySession(root)
    try await session.prepare()
    let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    let writer = try RecoverableMediaMaster(
      directory: session.mediaDirectory,
      identity: session.mediaMasterIdentity
    )
    let result = Self(root: root, session: session, repository: repository, writer: writer)
    for _ in 0..<seconds { try result.appendSecond() }
    return result
  }

  func appendSecond(denseStates: Bool = false) throws {
    let start = Int(writer.cursor.frames / 16)
    var samples = [Int16](repeating: 0, count: 32000)
    for frame in 0..<16000 { samples[frame * 2] = 321; samples[frame * 2 + 1] = -654 }
    let commit = try writer.append(
      interleaved: samples,
      microphoneIntervals: denseStates
        ? (0..<1000)
          .map {
            .init(
              startMs: start + $0,
              endMs: start + $0 + 1,
              state: $0 % 2 == 0 ? .recorded : .muted
            )
          } : [.init(startMs: start, endMs: start + 1000, state: .recorded)],
      applicationIntervals: denseStates
        ? (0..<1000)
          .map {
            .init(
              startMs: start + $0,
              endMs: start + $0 + 1,
              state: $0 % 2 == 0 ? .recorded : .unavailable
            )
          } : [.init(startMs: start, endMs: start + 1000, state: .recorded)]
    )
    try repository.commitMediaProgress(commit)
  }

  @discardableResult func finish(reason: String? = nil) async throws -> FinalizedMediaMaster {
    let master = try writer.finish()
    _ = try await repository.completeCapture(session, master: master, reason: reason)
    return master
  }

  var mediaURL: URL { session.mediaDirectory.appendingPathComponent("master.caf") }
  var indexURL: URL { session.mediaDirectory.appendingPathComponent("master.index") }
  var mediaExists: Bool { FileManager.default.fileExists(atPath: mediaURL.path) }
}

enum MasterUploadTransportFault: Sendable { case register, part, final, forgedReceipt, pausePart }

/// Keeps the server's admitted operation state across replacement client coordinators.
actor MasterUploadTestServer: MasterUploadTransport {
  private var registrations: [String: StoredDocument<MasterUploadSession>] = [:]
  private var calls: [String: CallDocument] = [:]
  private var parts: [String: [Int: StoredDocument<UploadPartReceipt>]] = [:]
  private var finals: [String: StoredDocument<VerifiedMasterReceipt>] = [:]
  private var fault: MasterUploadTransportFault?
  private(set) var registerRequests: [RegisterMasterUpload] = []
  private(set) var partRequests: [UploadPartDescriptor] = []
  private(set) var finalRequests: [FinalizeMasterUpload] = []
  private(set) var cancelledParts = 0
  private(set) var maximumBodyBytes = 0

  init(fault: MasterUploadTransportFault? = nil) { self.fault = fault }

  func register(_ request: RegisterMasterUpload) async throws -> StoredDocument<MasterUploadSession>
  {
    registerRequests.append(request)
    let call = try Contract.decode(CallDocument.self, bytes: Data(request.callDocument.utf8)).value
    calls[request.uploadId] = call
    let receipt =
      try registrations[request.uploadId]
      ?? stored(
        MasterUploadSession(
          schemaVersion: 1,
          archiveId: call.archiveId,
          callId: call.callId,
          uploadId: request.uploadId,
          masterId: request.masterId,
          partBytes: MediaMasterProfile.maximumRequestBytes,
          mediaProfileId: MediaMasterProfile.id
        )
      )
    registrations[request.uploadId] = receipt
    if fault == .register { fault = nil; throw lostAcknowledgement() }
    return receipt
  }

  func upload(
    callID: String,
    uploadID: String,
    part: UploadPartDescriptor,
    bytes: Data
  ) async throws -> StoredDocument<UploadPartReceipt> {
    partRequests.append(part)
    maximumBodyBytes = max(maximumBodyBytes, bytes.count)
    #expect(bytes.count == part.byteLength && Contract.hash(bytes) == part.sha256)
    if fault == .pausePart {
      fault = nil
      do { try await Task.sleep(for: .seconds(30)) } catch { cancelledParts += 1; throw error }
    }
    let registration = try #require(registrations[uploadID]).value
    let receipt =
      try parts[uploadID]?[part.index]
      ?? stored(
        UploadPartReceipt(
          schemaVersion: 1,
          archiveId: registration.archiveId,
          callId: callID,
          uploadId: uploadID,
          masterId: registration.masterId,
          index: part.index,
          byteOffset: part.byteOffset,
          byteLength: part.byteLength,
          sha256: part.sha256,
          receiptId: UUID().uuidString.lowercased()
        )
      )
    parts[uploadID, default: [:]][part.index] = receipt
    if fault == .part { fault = nil; throw lostAcknowledgement() }
    return receipt
  }

  func finalize(
    callID: String,
    request: FinalizeMasterUpload
  ) async throws -> StoredDocument<VerifiedMasterReceipt> {
    finalRequests.append(request)
    let registration = try #require(registrations[request.uploadId]).value
    let call = try #require(calls[request.uploadId])
    let duration = request.durationMs
    let audioBytes = Data(request.audioManifest.utf8)
    let audio = try Contract.decode(AudioManifest.self, bytes: audioBytes)
    let receipt =
      try finals[request.uploadId]
      ?? stored(
        VerifiedMasterReceipt(
          schemaVersion: 1,
          archiveId: call.archiveId,
          callId: callID,
          uploadId: request.uploadId,
          masterId: registration.masterId,
          operationId: request.operationId,
          receiptId: UUID().uuidString.lowercased(),
          verification: "complete-master-sha256-v1",
          mediaProfileId: MediaMasterProfile.id,
          masterSHA256: request.masterSHA256,
          sourceStatesSHA256: Contract.hash(
            #require(Data(base64Encoded: request.sourceStates.data))
          ),
          byteLength: duration * 64 + 68,
          durationMs: duration,
          channelMap: call.tracks.map {
            .init(channelIndex: $0.role == "microphone" ? 0 : 1, trackId: $0.trackId)
          },
          audioManifest: .init(manifestId: audio.value.manifestId, sha256: audio.sha256),
          storedAt: "2026-09-08T12:00:00.000Z"
        )
      )
    finals[request.uploadId] = receipt
    if fault == .final { fault = nil; throw lostAcknowledgement() }
    if fault == .forgedReceipt {
      fault = nil
      var forged = receipt.value
      forged.masterSHA256 = String(repeating: "0", count: 64)
      return try stored(forged)
    }
    return receipt
  }

  private func stored<T: ContractDocument>(_ value: T) throws -> StoredDocument<T> {
    try Contract.decode(T.self, bytes: Contract.encode(value))
  }
  private func lostAcknowledgement() -> MasterUploadError {
    .transport(code: "upload_response_lost", retry: .retryable)
  }
}

final class MasterUploadFault: @unchecked Sendable {
  private let lock = NSLock()
  private let target: MasterUploadPersistencePoint
  private var fired = false
  init(_ target: MasterUploadPersistencePoint) { self.target = target }
  func callAsFunction(_ point: MasterUploadPersistencePoint) throws {
    try lock.withLock {
      if point == target && !fired { fired = true; throw RepositoryInjectedFailure() }
    }
  }
}
