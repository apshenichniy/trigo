import Foundation
import Testing

@testable import TrigoContracts

private struct StructuralFixture: Decodable {
  let name: String
  let kind: String
  let json: String
  let valid: Bool
}

private func typedRoundTrip<Value: ContractDocument>(_ type: Value.Type, bytes: Data) throws -> Data
{
  let stored = try Contract.decodeStructure(type, bytes: bytes)
  #expect(stored.storedBytes == bytes)
  #expect(stored.sha256 == Contract.hash(bytes))
  return try JSONEncoder().encode(stored.value)
}

func typedRoundTrip(_ kind: String, bytes: Data) throws -> Data {
  switch kind {
  case "LocalDevelopmentBridge": try typedRoundTrip(LocalDevelopmentBridge.self, bytes: bytes)
  case "CaptureMasterProfile": try typedRoundTrip(CaptureMasterProfile.self, bytes: bytes)
  case "CallDocument": try typedRoundTrip(CallDocument.self, bytes: bytes)
  case "TranscriptRevision": try typedRoundTrip(TranscriptRevision.self, bytes: bytes)
  case "AudioManifest": try typedRoundTrip(AudioManifest.self, bytes: bytes)
  case "StatusResponse": try typedRoundTrip(StatusResponse.self, bytes: bytes)
  case "CommandIdentity": try typedRoundTrip(CommandIdentity.self, bytes: bytes)
  case "ErrorEnvelope": try typedRoundTrip(ErrorEnvelope.self, bytes: bytes)
  case "RegisterMasterUpload": try typedRoundTrip(RegisterMasterUpload.self, bytes: bytes)
  case "MasterUploadSession": try typedRoundTrip(MasterUploadSession.self, bytes: bytes)
  case "UploadPartDescriptor": try typedRoundTrip(UploadPartDescriptor.self, bytes: bytes)
  case "UploadPartReceipt": try typedRoundTrip(UploadPartReceipt.self, bytes: bytes)
  case "FinalizeMasterUpload": try typedRoundTrip(FinalizeMasterUpload.self, bytes: bytes)
  case "VerifiedMasterReceipt": try typedRoundTrip(VerifiedMasterReceipt.self, bytes: bytes)
  case "RequestTranscription": try typedRoundTrip(RequestTranscription.self, bytes: bytes)
  case "AvailableTranscript": try typedRoundTrip(AvailableTranscript.self, bytes: bytes)
  case "TranscriptionOperation": try typedRoundTrip(TranscriptionOperation.self, bytes: bytes)
  case "RequestPlayback": try typedRoundTrip(RequestPlayback.self, bytes: bytes)
  case "PlaybackManifest": try typedRoundTrip(PlaybackManifest.self, bytes: bytes)
  case "PlaybackGrant": try typedRoundTrip(PlaybackGrant.self, bytes: bytes)
  default: throw ContractError.structure
  }
}

@Test func sharedStructuralCorpusUsesGeneratedTypedViews() throws {
  let fixtures = try JSONDecoder()
    .decode(
      [StructuralFixture].self,
      from: Data(contentsOf: fixtureRoot.appendingPathComponent("structure-cases.json"))
    )
  for fixture in fixtures {
    let bytes = Data(fixture.json.utf8)
    do {
      let encoded = try typedRoundTrip(fixture.kind, bytes: bytes)
      #expect(fixture.valid, "Unexpected acceptance: \(fixture.name)")
      let original = try Contract.validateStructure(fixture.kind, bytes: bytes)
      let roundTrip = try Contract.validateStructure(fixture.kind, bytes: encoded)
      #expect(original.value == roundTrip.value, "Typed encoding changed fields: \(fixture.name)")
    } catch {
      #expect(!fixture.valid, "Unexpected rejection: \(fixture.name): \(error)")
    }
  }
}

@Test func typedViewsRetainExactBytesWithoutNormalizingWireScalars() throws {
  let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("valid-recording.json"))
  let stored = try Contract.decode(CallDocument.self, bytes: bytes)
  var edited = stored.value
  edited.startedAt = "2000-02-29T00:00:00.123456789Z"
  edited.archiveId = "abcdef12-abcd-1abc-0abc-abcdef123456"
  let newlyEncoded = try Contract.encode(edited)
  let decoded = try Contract.decode(CallDocument.self, bytes: newlyEncoded)
  #expect(decoded.value.startedAt == edited.startedAt)
  #expect(decoded.value.archiveId == edited.archiveId)
  #expect(stored.storedBytes == bytes)
  #expect(stored.sha256 == Contract.hash(bytes))
  #expect(Contract.hash(newlyEncoded) != stored.sha256)
  #expect(decoded.value.endedAt == nil)
  #expect(decoded.value.source.windowId == nil)
}

@Test func generatedDecoderAndEncoderRequireNullableKeys() throws {
  let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("valid-recording.json"))
  var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  object.removeValue(forKey: "endedAt")
  let absent = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: DecodingError.self) { try JSONDecoder().decode(CallDocument.self, from: absent) }
  let value = try Contract.decode(CallDocument.self, bytes: bytes).value
  let encoded = try Contract.encode(value)
  let published = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  for key in ["endedAt", "durationMs", "interruptionReason", "audioManifest", "activeRevisionId"] {
    #expect(published[key] is NSNull, "Missing required explicit null: \(key)")
  }
}
