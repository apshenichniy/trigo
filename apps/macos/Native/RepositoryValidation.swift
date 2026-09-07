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
    allowedSpeakerNameChange: SpeakerNameChange?
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
    let currentNames = current.speakerNames
    let proposedNames = proposed.speakerNames
    guard let allowedSpeakerNameChange else {
      guard currentNames == proposedNames else {
        throw LocalPersistenceError.manifestWouldChangeSpeakerAnnotations
      }
      return
    }
    let currentWithoutTarget = removingSpeakerName(
      revisionID: allowedSpeakerNameChange.revisionID,
      speakerID: allowedSpeakerNameChange.speakerID,
      from: currentNames
    )
    let proposedWithoutTarget = removingSpeakerName(
      revisionID: allowedSpeakerNameChange.revisionID,
      speakerID: allowedSpeakerNameChange.speakerID,
      from: proposedNames
    )
    let proposedTarget = proposedNames[allowedSpeakerNameChange.revisionID]?[
      allowedSpeakerNameChange.speakerID
    ]
    guard currentWithoutTarget == proposedWithoutTarget,
      proposedTarget == allowedSpeakerNameChange.name
    else {
      throw LocalPersistenceError.manifestWouldChangeSpeakerAnnotations
    }
  }
}

struct SpeakerNameChange {
  let revisionID: String
  let speakerID: String
  let name: String?
}

func removingSpeakerName(
  revisionID: String,
  speakerID: String,
  from names: [String: [String: String]]
) -> [String: [String: String]] {
  var result = names
  var revisionNames = result[revisionID] ?? [:]
  revisionNames.removeValue(forKey: speakerID)
  if revisionNames.isEmpty {
    result.removeValue(forKey: revisionID)
  } else {
    result[revisionID] = revisionNames
  }
  return result
}
