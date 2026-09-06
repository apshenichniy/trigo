import Foundation

public struct RecordingRecoveryFailure: Equatable, Sendable, Identifiable {
  public let callID: String
  public let message: String
  public var id: String { callID }
}

public struct RecordingRecoveryReport: Equatable, Sendable {
  public var recoveredCallIDs: [String] = []
  public var failures: [RecordingRecoveryFailure] = []
  public var warnings: [RecordingRecoveryFailure] = []
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
          let aggregate = try await CaptureArchiveSession.recover(root: root, callID: callID)
          let manifest = try jsonObject(aggregate.manifest.storedBytes)
          if manifest["captureState"] as? String == "interrupted" {
            report.recoveredCallIDs.append(callID)
            if manifest["interruptionReason"] as? String == "corrupt_media_tail" {
              report.warnings.append(
                .init(
                  callID: callID,
                  message:
                    "Corrupt media tail rejected. Only the verified prefix was recovered; the original files remain available for inspection."
                ))
            }
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
