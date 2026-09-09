import Foundation
import TrigoContracts

extension CanonicalSyncCoordinator {
  func allResults(callID: String) async throws -> [CatalogTranscriptResult] {
    var results: [CatalogTranscriptResult] = []
    var cursor: String?
    var generation = 0
    var seen = Set<String>()
    var revisionIDs = Set<String>()
    repeat {
      try Task.checkCancellation()
      let page = try await transport.results(callID: callID, cursor: cursor)
      guard page.archiveId == repository.archiveID, page.callId == callID, page.results.count <= 100
      else { throw CanonicalSyncError.invalidResult }
      for result in page.results {
        guard result.generation > generation, revisionIDs.insert(result.result.revisionId).inserted
        else { throw CanonicalSyncError.invalidResult }
        generation = result.generation
        results.append(result)
      }
      cursor = page.nextCursor
      if let cursor, !seen.insert(cursor).inserted { throw CanonicalSyncError.invalidResult }
    } while cursor != nil
    return results
  }

  func downloadResult(
    _ result: CatalogTranscriptResult,
    callID: String
  ) async throws -> (revision: Data, provenance: Data) {
    guard result.result.byteLength <= 16_000_000, result.result.provenanceByteLength <= 65_536
    else { throw CanonicalSyncError.incompatibleDocument }
    let revision = try await transport.revision(
      callID: callID,
      revisionID: result.result.revisionId
    )
    guard revision.count == result.result.byteLength,
      Contract.hash(revision) == result.result.sha256
    else { throw CanonicalSyncError.invalidResult }
    let provenance = try await transport.provenance(
      callID: callID,
      revisionID: result.result.revisionId
    )
    guard provenance.count == result.result.provenanceByteLength,
      Contract.hash(provenance) == result.result.provenanceSHA256
    else { throw CanonicalSyncError.invalidResult }
    return (revision, provenance)
  }

  func downloadReplica(
    callID: String,
    reference: ReplicaReference?,
    receipt: VerifiedMasterReceipt
  ) async throws -> ServerReplicaContents {
    let document = try await transport.document(callID: callID, version: reference?.documentVersion)
    if let reference {
      guard document.count == reference.byteLength, Contract.hash(document) == reference.sha256
      else { throw CanonicalSyncError.invalidResult }
    }
    let call = try Contract.decodeCallSnapshot(document).value
    guard call.callId == callID, call.archiveId == repository.archiveID,
      reference == nil || call.documentVersion == reference?.documentVersion
    else { throw CanonicalSyncError.invalidResult }
    let audio = try await transport.audioManifest(callID: callID)
    guard Contract.hash(audio) == call.audioManifest?.sha256 else {
      throw CanonicalSyncError.invalidResult
    }
    let available = try await allResults(callID: callID)
    var revisions: [String: Data] = [:]
    var provenance: [String: Data] = [:]
    for retained in call.revisions {
      try Task.checkCancellation()
      guard let result = available.first(where: { $0.result.revisionId == retained.revisionId }),
        result.result.sha256 == retained.sha256, result.result.createdAt == retained.createdAt
      else { throw CanonicalSyncError.invalidResult }
      let bytes = try await downloadResult(result, callID: callID)
      revisions[retained.revisionId] = bytes.revision
      provenance[retained.revisionId] = bytes.provenance
    }
    return try .init(
      document: document,
      audioManifest: audio,
      revisions: revisions,
      provenance: provenance,
      receipt: Contract.decode(VerifiedMasterReceipt.self, bytes: Contract.encode(receipt)),
      results: available.filter { result in
        call.revisions.contains { $0.revisionId == result.result.revisionId }
      }
    )
  }
}
