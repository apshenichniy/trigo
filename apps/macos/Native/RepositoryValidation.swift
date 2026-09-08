import Foundation
import TrigoContracts

extension LocalRepository {
  func validateAudioManifest(_ audio: AudioManifest, against call: CallDocument) throws {
    guard audio.callId == call.callId,
      call.captureState == "stopped" || call.captureState == "interrupted",
      let callDuration = call.durationMs, audio.durationMs == callDuration
    else { throw ContractError.reference }
    let trackIDs = Set(call.tracks.map(\.trackId))
    guard call.tracks.allSatisfy({ $0.mediaProfileId == audio.mediaProfileId }) else {
      throw ContractError.reference
    }
    for object in audio.objects {
      guard object.channelMap.allSatisfy({ trackIDs.contains($0.trackId) }) else {
        throw ContractError.reference
      }
    }
    for trackID in trackIDs {
      var cursor = 0
      for object in audio.objects where object.channelMap.contains(where: { $0.trackId == trackID })
      {
        guard object.startMs == cursor else { throw ContractError.reference }
        cursor = object.endMs
      }
      guard cursor == callDuration else { throw ContractError.reference }
    }
  }

  func validateEvolution(
    from current: CallDocument,
    to proposed: CallDocument,
    allowedAnnotationRevisionIDs: Set<String>
  ) throws {
    let currentRevisions = current.revisions
    let proposedRevisions = proposed.revisions
    guard proposedRevisions.count >= currentRevisions.count else {
      throw LocalPersistenceError.manifestWouldDiscardRevision(
        currentRevisions[proposedRevisions.count].revisionId
      )
    }
    for (index, retained) in currentRevisions.enumerated() {
      guard retained == proposedRevisions[index] else {
        throw LocalPersistenceError.manifestWouldDiscardRevision(retained.revisionId)
      }
    }
    if current.audioManifest != nil, current.audioManifest != proposed.audioManifest {
      throw LocalPersistenceError.manifestWouldChangeAudioManifest
    }
    guard
      current.speakerNames.filter({ !allowedAnnotationRevisionIDs.contains($0.key) })
        == proposed.speakerNames.filter({ !allowedAnnotationRevisionIDs.contains($0.key) }),
      current.speakerGroups.filter({ !allowedAnnotationRevisionIDs.contains($0.key) })
        == proposed.speakerGroups.filter({ !allowedAnnotationRevisionIDs.contains($0.key) })
    else {
      throw LocalPersistenceError.manifestWouldChangeSpeakerAnnotations
    }
  }
}
