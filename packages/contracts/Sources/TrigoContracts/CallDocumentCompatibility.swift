import Foundation

extension Contract {
  /// Select the exact closed wire shape before semantic/reference validation.
  public static func validateCallSnapshot(_ bytes: Data) throws -> ValidatedDocument {
    struct Header: Decodable { let schemaVersion: Int }
    let version: Int
    do { version = try JSONDecoder().decode(Header.self, from: bytes).schemaVersion } catch {
      throw ContractError.structure
    }
    guard version == 1 || version == 2 else { throw ContractError.structure }
    return try validate(version == 1 ? "LegacyCallDocument" : "CallDocument", bytes: bytes)
  }

  /// Legacy snapshots have an ungrouped current typed view while their original bytes
  /// stay unchanged. Publishing an upgrade requires a new repository document version.
  public static func decodeCallSnapshot(_ bytes: Data) throws -> StoredDocument<CallDocument> {
    let input = try validateCallSnapshot(bytes)
    if input.kind == "CallDocument" { return try typed(CallDocument.self, bytes: bytes) }
    let legacy = try typed(LegacyCallDocument.self, bytes: bytes).value
    return StoredDocument(
      value: .init(
        schemaVersion: 2,
        archiveId: legacy.archiveId,
        callId: legacy.callId,
        documentVersion: legacy.documentVersion,
        startedAt: legacy.startedAt,
        endedAt: legacy.endedAt,
        durationMs: legacy.durationMs,
        captureState: legacy.captureState,
        interruptionReason: legacy.interruptionReason,
        source: legacy.source,
        tracks: legacy.tracks,
        audioManifest: legacy.audioManifest,
        revisions: legacy.revisions,
        activeRevisionId: legacy.activeRevisionId,
        speakerNames: legacy.speakerNames,
        speakerGroups: [:]
      ),
      storedBytes: bytes
    )
  }
}
