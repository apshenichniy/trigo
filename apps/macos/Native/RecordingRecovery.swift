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

/// Discovers only direct call directories. No deletion, recursive discovery or stream restart.
enum RecordingRecovery {
  static func run(root: URL, archiveID: String) async -> RecordingRecoveryReport {
    var report = RecordingRecoveryReport()
    let files = FileManager.default
    do {
      try requireCanonicalIdentifier(archiveID)
      guard files.fileExists(atPath: root.path) else { return report }
      try requireUnlinked(root)
      let children = try files.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let metadataURL = directory.appendingPathComponent("capture-session.json")
        let properties = try directory.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        // A linked call directory is rejected without reading through it.
        if properties.isSymbolicLink == true {
          report.failures.append(
            .init(
              callID: directory.lastPathComponent,
              message:
                "Linked archive entry rejected. Restore the original local directory before retrying."
            ))
          continue
        }
        guard properties.isDirectory == true, files.fileExists(atPath: metadataURL.path) else {
          continue
        }
        let callID = directory.lastPathComponent
        do {
          try requireCanonicalIdentifier(callID)
          try requireUnlinked(metadataURL)
          let session = try JSONDecoder().decode(
            CaptureArchiveSession.self, from: Data(contentsOf: metadataURL))
          guard session.callID == callID, session.archiveID == archiveID,
            session.root.standardizedFileURL.path == root.standardizedFileURL.path
          else { throw CaptureError.corruptCheckpoint }
          // Recovery reads/writes known direct call files and direct media objects. Reject
          // linked inputs there too; discovery never descends into unrelated directories.
          try rejectLinkedChildren(directory)
          if files.fileExists(atPath: session.mediaDirectory.path) {
            try rejectLinkedChildren(session.mediaDirectory)
          }
          guard try await needsRecovery(session) else { continue }
          let aggregate = try await CaptureArchiveSession.recover(root: root, callID: callID)
          let manifest = try jsonObject(aggregate.manifest.storedBytes)
          let reason = manifest["interruptionReason"] as? String
          report.recoveredCalls.append(.init(callID: callID, interruptionReason: reason))
          if reason == "corrupt_media_tail" {
            report.warnings.append(
              .init(
                callID: callID,
                message:
                  "Corrupt media tail rejected. Only the verified prefix was recovered; the original files remain available for inspection."
              ))
          }
        } catch {
          report.failures.append(
            .init(
              callID: callID,
              message:
                "Recovery rejected or failed. Verify this call's metadata, archive identity, free disk space and file access, then retry. Retained files have not been deleted."
            ))
        }
      }
    } catch {
      report.failures.append(
        .init(
          callID: "archive",
          message:
            "Cannot read the local archive. Check file access and free disk space, then retry recovery."
        ))
    }
    return report
  }

  private static func needsRecovery(_ session: CaptureArchiveSession) async throws -> Bool {
    let archive = try LocalArchive(root: session.root, archiveID: session.archiveID)
    let lifecycle = try LocalLifecycleStore(root: session.root, archiveID: session.archiveID)
    do {
      let call = try await archive.loadCall(callID: session.callID)
      let manifest = try jsonObject(call.manifest.storedBytes)
      guard manifest["audioManifest"] is [String: Any],
        let state = manifest["captureState"] as? String, state != "recording"
      else { return true }
      let current = try await lifecycle.load(callID: session.callID)
      return current?.capture.state.rawValue != state
        || current?.capture.failure?.code != manifest["interruptionReason"] as? String
    } catch LocalPersistenceError.callNotFound {
      return true
    }
  }

  private static func requireUnlinked(_ url: URL) throws {
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw CaptureError.corruptCheckpoint
    }
  }

  private static func rejectLinkedChildren(_ directory: URL) throws {
    try requireUnlinked(directory)
    for child in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
    {
      try requireUnlinked(child)
    }
  }
}
