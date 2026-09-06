import Foundation

public struct RecordingRecoveryFailure: Equatable, Sendable, Identifiable {
  public let callID: String
  public let message: String
  public var id: String { callID }
}

public struct RecordingRecoveryReport: Equatable, Sendable {
  public var recoveredCalls: [RecoveredRecording] = []
  public var recoveredCallIDs: [String] { recoveredCalls.map(\.callID) }
  public var failures: [RecordingRecoveryFailure] = []
  public var warnings: [RecordingRecoveryFailure] = []
}

public struct RecoveredRecording: Equatable, Sendable, Identifiable {
  public let callID: String
  public let interruptionReason: String?
  public var id: String { callID }
  public var explanation: String {
    switch interruptionReason {
    case "process_terminated": "The process ended before recording was finalized."
    case "application_termination": "The app quit before recording was finalized."
    case "system_sleep": "System sleep interrupted recording."
    case "source_exited": "The selected application exited."
    case "duration_limit": "The three-hour recording limit was reached."
    case "media_write_failed":
      "Local media writing failed. Check free disk space and archive access."
    case "application_stream_failed":
      "The application capture stream failed. Check capture permissions before recording again."
    case "corrupt_media_tail":
      "A corrupt media tail was rejected; only the verified prefix was recovered."
    case .some(let reason):
      "Recorded interruption: \(reason.replacingOccurrences(of: "_", with: " "))."
    case nil: "Pending finalization completed; no interruption cause was recorded."
    }
  }
}

/// SQLite owns metadata recovery. Only admitted direct sessions can trigger external media
/// recovery; unfamiliar stores and unsafe paths fail without deletion or recursive discovery.
enum RecordingRecovery {
  static func run(root: URL, archiveID: String) async -> RecordingRecoveryReport {
    var report = RecordingRecoveryReport()
    let files = FileManager.default
    do {
      try requireCanonicalIdentifier(archiveID)
      guard files.fileExists(atPath: root.path) else { return report }
      try requireSafePath(root, directory: true)
      let repository = try LocalRepository(root: root, archiveID: archiveID)
      for child in try files.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
      {
        if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
          report.failures.append(
            .init(
              callID: child.lastPathComponent,
              message: "Linked archive entry rejected; retained evidence has not been changed."))
        }
      }
      var after: String?
      while true {
        let calls = try await repository.calls(after: after)
        for call in calls where call.captureState == .recording {
          do {
            guard let session = try await repository.captureSession(callID: call.callID) else {
              continue
            }
            let directory = session.mediaDirectory.deletingLastPathComponent()
            if files.fileExists(atPath: directory.path) { try rejectLinkedChildren(directory) }
            if files.fileExists(atPath: session.mediaDirectory.path) {
              try rejectLinkedChildren(session.mediaDirectory)
            }
            let aggregate = try await session.recover()
            let reason = aggregate.manifest.value.interruptionReason
            report.recoveredCalls.append(.init(callID: call.callID, interruptionReason: reason))
            if reason == "corrupt_media_tail" {
              report.warnings.append(
                .init(
                  callID: call.callID,
                  message:
                    "Corrupt media tail rejected. Only the verified prefix was recovered; original files remain available for inspection."
                ))
            }
          } catch {
            report.failures.append(
              .init(
                callID: call.callID,
                message:
                  "Recovery rejected or failed. Verify metadata, archive identity, free disk space and file access; retained evidence has not been deleted."
              ))
          }
        }
        if calls.count < 100 { break }
        after = calls.last?.callID
      }
    } catch {
      report.failures.append(
        .init(
          callID: "archive",
          message:
            "Cannot open the local archive. Its identity, version, integrity or file access requires attention; no automatic reset was performed."
        ))
    }
    return report
  }

  private static func rejectLinkedChildren(_ directory: URL) throws {
    try requireSafePath(directory, directory: true)
    for child in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
    {
      guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw LocalPersistenceError.unsafeStore(child.lastPathComponent)
      }
    }
  }
}
