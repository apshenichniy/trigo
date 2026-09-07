import Foundation

public enum CaptureError: Error, Equatable, Sendable {
  case invalidAudio
  case closed
  case durationLimit
}

/// The capture queue owns this writer. Each bounded append synchronizes external media,
/// then publishes exactly that certificate in SQLite before accepting more timeline input.
/// A failed/uncertain publication closes this instance; reopen reconciles without re-appending PCM.
public final class CaptureMediaWriter {
  public let session: CaptureArchiveSession
  let master: RecoverableMediaMaster
  private let repository: LocalRepository
  #if DEBUG
    // TEMP-57-OVERFLOW: separate recoverable master I/O from SQLite publication.
    var diagnostics: CaptureOverflowDiagnostics?
  #endif
  private var failed = false
  private let appendingAllowed: Bool
  public var durationMs: Int { Int(master.cursor.frames / 16) }

  public convenience init(session: CaptureArchiveSession) throws {
    try self.init(session: session, io: MediaMasterIO())
  }

  init(session: CaptureArchiveSession, io: MediaMasterIO) throws {
    self.session = session
    appendingAllowed = true
    repository = try LocalRepository(root: session.root, archiveID: session.archiveID)
    guard try repository.masterIdentity(session.callID) == session.mediaMasterIdentity else {
      throw MediaMasterError.identityMismatch
    }
    try FileManager.default.createDirectory(
      at: session.mediaDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    master = try RecoverableMediaMaster(
      directory: session.mediaDirectory, identity: session.mediaMasterIdentity, io: io)
  }

  private init(recovering session: CaptureArchiveSession) throws {
    self.session = session
    appendingAllowed = false
    repository = try LocalRepository(root: session.root, archiveID: session.archiveID)
    let confirmed =
      try repository.confirmedMediaCursor(callID: session.callID)
      ?? repository.initialCursor(session.mediaMasterIdentity)
    master = try RecoverableMediaMaster(
      reopening: session.mediaDirectory, expectedIdentity: session.mediaMasterIdentity,
      confirmed: confirmed)
    try master.forEachCommit(intersecting: confirmed.frames..<master.cursor.frames) { commit in
      try repository.commitMediaProgress(commit)
    }
  }

  /// Reopen never resumes device recording. Old committed corruption is an error; only the
  /// master boundary may discard an uncommitted tail after checking the repository witness.
  public static func recover(session: CaptureArchiveSession) throws -> CaptureMediaWriter {
    try CaptureMediaWriter(recovering: session)
  }

  public func append(
    interleaved: [Int16], microphoneIntervals: [CaptureInterval]? = nil,
    applicationIntervals: [CaptureInterval]? = nil
  ) throws {
    guard appendingAllowed, !failed, master.finalized == nil else { throw CaptureError.closed }
    guard !interleaved.isEmpty, interleaved.count % 32 == 0, interleaved.count <= 32_000 else {
      throw CaptureError.invalidAudio
    }
    guard master.cursor.frames + Int64(interleaved.count / 2) <= MediaMasterProfile.maximumFrames
    else { throw CaptureError.durationLimit }
    let start = durationMs
    let end = start + interleaved.count / 32
    #if DEBUG
      diagnostics?.record(.init(kind: .writerStart, frames: interleaved.count / 2))
    #endif
    do {
      let commit = try master.append(
        interleaved: interleaved,
        microphoneIntervals: microphoneIntervals ?? [
          .init(startMs: start, endMs: end, state: .recorded)
        ],
        applicationIntervals: applicationIntervals ?? [
          .init(startMs: start, endMs: end, state: .recorded)
        ])
      #if DEBUG
        diagnostics?.record(.init(kind: .masterAppendFinish))
      #endif
      try repository.commitMediaProgress(commit)
      #if DEBUG
        diagnostics?.record(.init(kind: .sqliteCommitFinish))
      #endif
    } catch {
      #if DEBUG
        diagnostics?.record(.init(kind: .writerFailed))
      #endif
      failed = true
      throw error
    }
  }

  /// The durable stop request must already exist before this external finalization.
  public func finish() throws -> FinalizedMediaMaster {
    guard !failed else { throw CaptureError.closed }
    guard try repository.captureStopRequest(callID: session.callID) != nil else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    do { return try master.finish() } catch {
      failed = true
      throw error
    }
  }

  public var identity: MediaMasterIdentity { session.mediaMasterIdentity }

  public func confirmedCursor() throws -> MediaMasterCursor {
    try repository.confirmedMediaCursor(callID: session.callID)
      ?? repository.initialCursor(identity)
  }

  public func finalizedMaster() throws -> FinalizedMediaMaster? {
    try repository.finalizedMaster(callID: session.callID)
  }

  /// Only repository-confirmed bytes are uploadable, including after an uncertain append.
  public func readStableBytes(in range: Range<Int64>) throws -> Data {
    guard range.upperBound <= (try confirmedCursor()).stableBytes else {
      throw MediaMasterError.invalidInput
    }
    return try master.readStableBytes(in: range)
  }

  /// Post-call extraction is available once the same final master witness is committed.
  public func extract(
    frames: Range<Int64>, to destination: URL,
    intervals: (MediaMasterSourceIntervals) throws -> Void = { _ in }
  ) throws -> MediaMasterExtraction {
    guard let final = try finalizedMaster(), master.finalized == final else {
      throw MediaMasterError.invalidInput
    }
    return try master.extract(frames: frames, to: destination, intervals: intervals)
  }

  func recordFailure() throws {
    try repository.recordCaptureMediaFailure(callID: session.callID)
  }

  func requestStop(reason: String?) throws {
    try repository.requestCaptureStop(callID: session.callID, reason: reason)
  }
}

extension FinalizedMediaMaster {
  public var durationMs: Int { Int(cursor.frames / 16) }
}
