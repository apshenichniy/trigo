import Foundation
import JSONSchema

extension Contract {
  static func validateCall(_ call: JSONValue) throws {
    let tracks = call["tracks"].items
    try unique(tracks.map { $0["trackId"] })
    try unique(tracks.map { $0["role"] })
    let finalized = call["captureState"].text != "recording"
    try require(
      finalized
        ? !call["durationMs"].isNull && !call["endedAt"].isNull
        : call["durationMs"].isNull && call["endedAt"].isNull)
    if !call["endedAt"].isNull {
      func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if text.contains(".") { f.formatOptions.insert(.withFractionalSeconds) }
        return f.date(from: text)
      }
      if let start = date(call["startedAt"].text), let end = date(call["endedAt"].text) {
        try require(end >= start)
      } else {
        throw ContractError.semantics
      }
    }
    try require(
      call["captureState"].text == "interrupted"
        ? !call["interruptionReason"].isNull : call["interruptionReason"].isNull)
    for track in tracks {
      var cursor = 0
      for interval in track["intervals"].items {
        try require(
          interval["endMs"].integerValue > interval["startMs"].integerValue
            && interval["startMs"].integerValue == cursor)
        try require(interval["state"].text != "muted" || track["role"].text == "microphone")
        cursor = interval["endMs"].integerValue
      }
      if finalized { try require(cursor == call["durationMs"].integerValue) }
    }
    try unique(call["revisions"].items.map { $0["revisionId"] })
    try require(
      call["activeRevisionId"].isNull
        || call["revisions"].items.contains { $0["revisionId"] == call["activeRevisionId"] })
  }
  static func validateRevision(_ revision: JSONValue) throws {
    let speakers = revision["speakers"].items
    let turns = revision["turns"].items
    try unique(speakers.map { $0["speakerId"] })
    try unique(turns.map { $0["turnId"] })
    var previousStart = 0
    for turn in turns {
      let start = turn["startMs"].integerValue
      let end = turn["endMs"].integerValue
      try require(start >= previousStart && end >= start)
      previousStart = start
      if !turn["speakerId"].isNull {
        try require(
          speakers.contains {
            $0["speakerId"] == turn["speakerId"] && $0["trackId"] == turn["trackId"]
          })
      }
      var cursor = start
      for word in turn["words"].items {
        try require(
          word["startMs"].integerValue >= cursor
            && word["endMs"].integerValue >= word["startMs"].integerValue
            && word["endMs"].integerValue <= end)
        cursor = word["endMs"].integerValue
      }
    }
  }
  static func validateAudio(_ audio: JSONValue) throws {
    let profile = try MediaProfile.selected()
    try require(audio["mediaProfileId"].text == profile.id.rawValue)
    let objects = audio["objects"].items
    try unique(objects.map { $0["objectId"] })
    try unique(objects.map { $0["index"] })
    var index = -1
    var start = 0
    for object in objects {
      try require(
        object["index"].integerValue > index && object["startMs"].integerValue >= start
          && object["endMs"].integerValue > object["startMs"].integerValue
          && object["endMs"].integerValue <= audio["durationMs"].integerValue)
      index = object["index"].integerValue
      start = object["startMs"].integerValue
      try unique(object["channelMap"].items.map { $0["channelIndex"] })
      try unique(object["channelMap"].items.map { $0["trackId"] })
      let durationMs = object["endMs"].integerValue - object["startMs"].integerValue
      try require(durationMs <= profile.objectDurationMs)
      let frameCount = profile.frameCount(durationMs: durationMs)
      try require(
        object["contentType"].text == profile.contentType.rawValue
          && object["byteLength"].integerValue == profile.waveByteLength(frameCount: frameCount)
          && object["byteLength"].integerValue <= profile.maxObjectBytes
          && object["byteLength"].integerValue <= profile.limits.uploadRequestBytes
          && object["channelMap"].items.count == profile.channels.count
          && profile.channels.allSatisfy { expected in
            object["channelMap"].items.contains {
              $0["channelIndex"].integerValue == expected.index
            }
          })
    }
  }
}
