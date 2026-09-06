import CryptoKit
import Foundation
import JSONSchema

public enum ContractError: String, Error { case structure, semantics, reference, checksum }

/// Retains every validated field and the original immutable UTF-8 bytes.
public struct ValidatedDocument: Sendable {
  public let kind: String
  public let value: JSONValue
  public let storedBytes: Data
  public var callId: String? { value["callId"].string }
  public var revisionId: String? { value["revisionId"].string }
  public var documentVersion: Int? { value["documentVersion"].integer }
  public func serialized() throws -> Data { try JSONEncoder().encode(value) }
}

extension JSONValue {
  subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
  var items: [JSONValue] { array ?? [] }
  var text: String { string ?? "" }
  var integerValue: Int { Int(numeric ?? 0) }
}

struct UTCFormat: FormatValidator {
  let formatName = "date-time"
  func validate(_ value: String) -> Bool {
    let parts = value.split(whereSeparator: { !($0.isNumber) }).compactMap { Int($0) }
    guard parts.count >= 6 else { return false }
    let year = parts[0]
    let month = parts[1]
    let day = parts[2]
    guard (1...12).contains(month) else { return false }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...days[month - 1]).contains(day) && parts[3] < 24 && parts[4] < 60
      && (parts[5] < 60 || (parts[3] == 23 && parts[4] == 59 && parts[5] == 60))
  }
}

public enum Contract {
  public static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  static func require(_ condition: Bool, _ error: ContractError = .semantics) throws {
    if !condition { throw error }
  }
  static func unique(_ values: [JSONValue]) throws {
    try require(Set(values).count == values.count)
  }
  public static func validateStructure(_ kind: String, bytes: Data) throws -> ValidatedDocument {
    guard let text = String(data: bytes, encoding: .utf8) else { throw ContractError.structure }
    do {
      let url = Bundle.module.url(forResource: "v1.schema", withExtension: "json")!
      var root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object!
      guard root["$defs"]?[kind] != .null else { throw ContractError.structure }
      root.removeValue(forKey: "oneOf")
      root["$ref"] = .string("#/$defs/\(kind)")
      let schemaBytes = try JSONEncoder().encode(JSONValue.object(root))
      let schema = try Schema(
        instance: String(decoding: schemaBytes, as: UTF8.self), formatValidators: [UTCFormat()])
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
      try require(schema.validate(value).isValid, .structure)
      return ValidatedDocument(kind: kind, value: value, storedBytes: bytes)
    } catch { throw ContractError.structure }
  }
  public static func validate(_ kind: String, bytes: Data) throws -> ValidatedDocument {
    let result = try validateStructure(kind, bytes: bytes)
    switch kind {
    case "CallDocument": try validateCall(result.value)
    case "TranscriptRevision": try validateRevision(result.value)
    case "AudioManifest": try validateAudio(result.value)
    default: break
    }
    return result
  }
  public static func validateArchive(_ bytes: Data, references: [String: Data]) throws
    -> ValidatedDocument
  {
    let result = try validate("CallDocument", bytes: bytes)
    let call = result.value
    func resolve(_ kind: String, _ id: String, _ hash: String) throws -> JSONValue {
      guard let bytes = references[id] else { throw ContractError.reference }
      try require(Self.hash(bytes) == hash, .checksum)
      return try validate(kind, bytes: bytes).value
    }
    var audio: JSONValue = .null
    let tracks = call["tracks"].items
    if !call["audioManifest"].isNull {
      let ref = call["audioManifest"]
      audio = try resolve("AudioManifest", ref["manifestId"].text, ref["sha256"].text)
      try require(
        audio["callId"] == call["callId"] && audio["manifestId"] == ref["manifestId"]
          && audio["durationMs"] == call["durationMs"], .reference)
      for track in tracks {
        try require(track["mediaProfileId"] == audio["mediaProfileId"], .reference)
      }
      let profile = try MediaProfile.selected()
      for object in audio["objects"].items {
        for expected in profile.channels {
          guard
            let channel = object["channelMap"].items.first(where: {
              $0["channelIndex"].integerValue == expected.index
            })
          else { throw ContractError.reference }
          try require(
            tracks.contains {
              $0["trackId"] == channel["trackId"]
                && $0["role"].text == expected.role.rawValue
            }, .reference)
        }
      }
      for track in tracks {
        var cursor = 0
        for object in audio["objects"].items.filter({
          $0["channelMap"].items.contains { $0["trackId"] == track["trackId"] }
        }) {
          try require(object["startMs"].integerValue == cursor, .reference)
          cursor = object["endMs"].integerValue
        }
        try require(cursor == audio["durationMs"].integerValue, .reference)
      }
    }
    var revisions: [String: JSONValue] = [:]
    var speakerIds = Set<JSONValue>()
    var turnIds = Set<JSONValue>()
    for ref in call["revisions"].items {
      let revision = try resolve("TranscriptRevision", ref["revisionId"].text, ref["sha256"].text)
      try require(
        revision["callId"] == call["callId"] && revision["revisionId"] == ref["revisionId"]
          && revision["createdAt"] == ref["createdAt"], .reference)
      try require(!audio.isNull && revision["audioManifest"] == call["audioManifest"], .reference)
      for speaker in revision["speakers"].items {
        try require(tracks.contains { $0["trackId"] == speaker["trackId"] }, .reference)
      }
      for turn in revision["turns"].items {
        try require(
          tracks.contains { $0["trackId"] == turn["trackId"] }
            && turn["endMs"].integerValue <= call["durationMs"].integerValue, .reference)
      }
      for speaker in revision["speakers"].items {
        try require(speakerIds.insert(speaker["speakerId"]).inserted, .reference)
      }
      for turn in revision["turns"].items {
        try require(turnIds.insert(turn["turnId"]).inserted, .reference)
      }
      revisions[ref["revisionId"].text] = revision
    }
    for (revisionId, names) in call["speakerNames"].object! {
      guard let revision = revisions[revisionId] else { throw ContractError.reference }
      for speakerId in names.object!.keys {
        try require(
          revision["speakers"].items.contains { $0["speakerId"].text == speakerId }, .reference)
      }
    }
    return result
  }
}
