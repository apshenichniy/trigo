import Foundation
import TrigoContracts

extension LocalRepository {
  /// Store evolution never rewrites old evidence or relabels an old snapshot's hash.
  /// An explicit new v2 publication becomes canonical before it can leave this Mac.
  public func upgradeLegacyCallSnapshots() async throws {
    for callID in try await callIDs() {
      guard let priorHash = try currentHash(callID) else { continue }
      let prior = try storedCall(hash: priorHash)
      guard try Contract.validateCallSnapshot(prior.storedBytes).kind == "LegacyCallDocument" else {
        continue
      }
      let upgrade = try await prepareLegacyUpgrade(prior)
      try database.access {
        try database.transaction(interruption: interruption) {
          _ = try commitCall(
            upgrade.snapshot.value,
            hash: upgrade.snapshot.sha256,
            expected: priorHash
          )
          if let operation = upgrade.operation {
            try commitReplicaWork(operation, snapshot: upgrade.snapshot, annotationRevisionIDs: [])
          }
        }
      }
    }
  }

  func prepareLegacyUpgrade(
    _ legacy: StoredDocument<CallDocument>
  ) async throws -> PreparedLegacyUpgrade {
    var value = legacy.value
    value.documentVersion += 1
    let snapshot = StoredDocument(value: value, storedBytes: try Contract.encode(value))
    try await stageCall(snapshot)
    let operation: PreparedOperation?
    if value.captureState != "recording", value.audioManifest != nil {
      operation = try await prepareOperation(
        .init(
          operationID: UUID().uuidString.lowercased(),
          archiveID: archiveID,
          callID: value.callId,
          kind: .replica,
          payload: snapshot.storedBytes
        )
      )
    } else {
      operation = nil
    }
    return .init(snapshot: snapshot, operation: operation)
  }
}

struct PreparedLegacyUpgrade: Sendable {
  let snapshot: StoredDocument<CallDocument>
  let operation: PreparedOperation?
}
