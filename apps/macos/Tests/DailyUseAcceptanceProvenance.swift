import CryptoKit
import Foundation
import TrigoContracts

@testable import TrigoNative

struct DailyUseProviderReceipt: Decodable {
  struct Transport: Decodable {
    let deliveryWitness: String
    let deliveredByteLength: Int?
    let responseBodyComplete: Bool?
    let providerHttpStatus: Int?
    let uploadedByteLength: Int?
    let inputSHA256: String?
    let uploadHttpStatus: Int?
    let uploadURL: String?
  }
  let transport: Transport
  let providerRequestId: String?
  let reportedDurationSeconds: Double?

  func validate(byteLength: Int, frameCount: Int, inputSHA256: String? = nil) throws {
    if transport.deliveryWitness == "http-upload-ack-v1" {
      try requireDailyUse(
        transport.uploadedByteLength == byteLength && transport.uploadHttpStatus == 200
          && inputSHA256 != nil && transport.inputSHA256 == inputSHA256
          && transport.uploadURL.flatMap { URL(string: $0) }?.scheme == "https"
          && transport.uploadURL.flatMap { URL(string: $0) }?.host?.hasSuffix(".assemblyai.com")
            == true
          && providerRequestId?.isEmpty == false
          && reportedDurationSeconds.map { abs($0 * 16_000 - Double(frameCount)) <= 16_000 }
            == true,
        "ASR submission lacks a matching upload acknowledgment or coarse provider duration."
      )
      return
    }
    try requireDailyUse(
      transport.deliveryWitness == "consumer-eof-v1"
        && transport.deliveredByteLength == byteLength && transport.responseBodyComplete == true
        && transport.providerHttpStatus == 200 && providerRequestId?.isEmpty == false
        && reportedDurationSeconds.map { abs($0 * 16_000 - Double(frameCount)) <= 1 } != false,
      "ASR submission lacks a complete provider receipt or reports a mismatched duration."
    )
  }
}

// This decoder inspects independent retained server evidence. The public transcript
// still passes the shared contract validator before any acceptance assertions.
private struct DailyUseProvenance: Decodable {
  struct Master: Decodable, Equatable {
    let callId: String
    let masterId: String
    let manifestId: String
    let manifestSha256: String
    let sha256: String
    let frameCount: Int
    let byteLength: Int
    let mediaProfileId: String
    let microphoneTrackId: String
    let applicationTrackId: String
  }
  struct Submission: Decodable {
    struct Extraction: Decodable {
      struct Interval: Decodable {
        let submissionId: String
        let index: Int
        let startFrame: Int
        let endFrame: Int
      }
      let schemaVersion: Int
      let master: Master
      let interval: Interval
      let transform: String
      let contentType: String
      let codec: String
      let sampleRateHz: Int
      let channels: Int
      let microphoneChannel: Int
      let applicationChannel: Int
      let byteLength: Int
      let sha256: String
      let startMs: Int
      let endMs: Int
    }
    struct Artifact: Decodable {
      let key: String
      let sha256: String
      let byteLength: Int
    }
    let extraction: Extraction
    let transport: DailyUseProviderReceipt.Transport
    let rawArtifact: Artifact
    let providerRequestId: String?
    let reportedDurationSeconds: Double?
  }
  let schemaVersion: Int
  let callId: String
  let revisionId: String
  let profileId: String
  let providerInvoked: Bool
  let allConsumerEOFVerified: Bool?
  let allUploadsAcknowledged: Bool?
  let sourceStatesSHA256: String
  let masterReceiptId: String
  let master: Master
  let submissions: [Submission]
}

func verifyDailyUseProvenance(
  bytes: Data,
  revision: TranscriptRevision,
  receipt: VerifiedMasterReceipt,
  plan: DailyUsePlan,
  template: DailyUseTemplate,
  local: Bool
) throws -> [String: Any] {
  let value = try JSONDecoder().decode(DailyUseProvenance.self, from: bytes)
  let master = value.master
  try requireDailyUse(
    value.schemaVersion == 1 && value.callId == plan.callID && value.revisionId == plan.revisionID
      && value.profileId == "assemblyai-u2-wav-s16le-16000-stereo-v1"
      && value.providerInvoked == !local && value.sourceStatesSHA256 == plan.sourceStatesSHA256
      && value.masterReceiptId == receipt.receiptId
      && master.callId == plan.callID && master.masterId == plan.masterID
      && master.manifestId == plan.manifestID
      && master.manifestSha256 == receipt.audioManifest.sha256
      && master.sha256 == plan.masterSHA256 && master.byteLength == plan.byteLength
      && master.frameCount == plan.durationMs * 16
      && master.microphoneTrackId == plan.microphoneTrackID
      && master.applicationTrackId == plan.applicationTrackID
      && master.mediaProfileId == "caf-lpcm-s16le-16000-stereo-v1"
      && revision.audioManifest == receipt.audioManifest
      && revision.asr.profileId == value.profileId && revision.asr.requestedLanguage == "en",
    "The retained provenance, revision and verified master do not identify the admitted input."
  )
  if local {
    try requireDailyUse(
      revision.asr.adapter == "fake" && revision.asr.model == "no-speech"
        && revision.turns.isEmpty && revision.speakers.isEmpty,
      "The local rehearsal is not the explicit no-speech fake provider."
    )
  } else {
    try requireDailyUse(
      revision.asr.adapter == "assemblyai" && revision.asr.model == "universal-2"
        && value.allUploadsAcknowledged == true && !revision.asr.providerRequestIds.isEmpty,
      "Hosted acceptance lacks actual AssemblyAI upload acknowledgment evidence."
    )
  }
  let count = (plan.durationMs + 7_199_999) / 7_200_000
  try requireDailyUse(
    value.submissions.count == count
      && Set(value.submissions.map { $0.extraction.interval.submissionId }).count == count
      && Set(value.submissions.map { $0.rawArtifact.key }).count == count,
    "The result does not retain every independent submission exactly once."
  )
  var cursor = 0
  for (index, submission) in value.submissions.enumerated() {
    let extraction = submission.extraction
    let end = min(plan.durationMs, cursor + 7_200_000)
    let byteLength = 44 + (end - cursor) * 64
    try requireDailyUse(
      extraction.schemaVersion == 1 && extraction.master == master
        && extraction.interval.index == index && extraction.interval.startFrame == cursor * 16
        && extraction.interval.endFrame == end * 16
        && extraction.startMs == cursor && extraction.endMs == end
        && extraction.transform == "caf-lpcm-to-wave-pcm-frame-slice-v1"
        && extraction.contentType == "audio/wav" && extraction.codec == "pcm_s16le"
        && extraction.sampleRateHz == 16_000 && extraction.channels == 2
        && extraction.microphoneChannel == 0 && extraction.applicationChannel == 1
        && extraction.byteLength == byteLength
        && extraction.sha256
          == template.waveHash(startMs: cursor, endMs: end, durationMs: plan.durationMs)
        && submission.rawArtifact.byteLength > 0
        && submission.rawArtifact.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression)
          != nil,
      "ASR extraction \(index) did not preserve the complete planned frames, source channels or bytes."
    )
    if !local {
      try requireDailyUse(
        submission.transport.deliveryWitness == "http-upload-ack-v1",
        "AssemblyAI acceptance requires an HTTP upload acknowledgment."
      )
      try DailyUseProviderReceipt(
        transport: submission.transport,
        providerRequestId: submission.providerRequestId,
        reportedDurationSeconds: submission.reportedDurationSeconds
      )
      .validate(
        byteLength: byteLength,
        frameCount: (end - cursor) * 16,
        inputSHA256: extraction.sha256
      )
    }
    cursor = end
  }
  try requireDailyUse(cursor == plan.durationMs, "The final ASR interval is truncated.")
  let markerProof = local ? ["applicable": false] : try template.verifyMarkers(revision, plan: plan)
  return [
    "providerInvoked": value.providerInvoked, "submissionCount": count,
    "completeFrameCount": master.frameCount, "completeByteLength": master.byteLength,
    "allConsumerEOFVerified": value.allConsumerEOFVerified ?? false,
    "allUploadsAcknowledged": value.allUploadsAcknowledged ?? false,
    "sourceChannels": 2, "markerCoverage": markerProof,
    "reportedDurationsSeconds": value.submissions.map {
      $0.reportedDurationSeconds.map { $0 as Any } ?? NSNull()
    },
    "reportedDurationAvailable": value.submissions.map { $0.reportedDurationSeconds != nil },
  ]
}

extension DailyUseTemplate {
  /// Independent WAV header/hash calculation, without using server extraction code.
  func waveHash(startMs: Int, endMs: Int, durationMs: Int) -> String {
    let payload = (endMs - startMs) * 64
    var header = Data()
    func number<Value: FixedWidthInteger>(_ value: Value) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
    }
    header.append(contentsOf: "RIFF".utf8); number(UInt32(payload + 36))
    header.append(contentsOf: "WAVEfmt ".utf8); number(UInt32(16))
    number(UInt16(1)); number(UInt16(2)); number(UInt32(16_000)); number(UInt32(64_000))
    number(UInt16(4)); number(UInt16(16)); header.append(contentsOf: "data".utf8)
    number(UInt32(payload))
    var digest = SHA256()
    digest.update(data: header)
    for second in (startMs / 1000)..<(endMs / 1000) {
      digest.update(data: pcmSecond(second, durationMs: durationMs))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func verifyMarkers(_ revision: TranscriptRevision, plan: DailyUsePlan) throws -> [String: Any] {
    let words = Dictionary(grouping: revision.turns, by: \.trackId)
      .mapValues {
        $0.flatMap(\.words).sorted { $0.startMs < $1.startMs }
      }
    let blocks = plan.durationMs / 20_000
    var verified = 0
    var verifiedAnchors = 0
    var missing: [[String: Any]] = []
    for block in 0..<blocks {
      let source = sourceSecond(block * 20, durationMs: plan.durationMs) / 20
      for event in events where event.block == source {
        let start = Double(block * 20_000 - source * 20_000) + event.startMs
        let end = Double(block * 20_000 - source * 20_000) + event.endMs
        let track = event.channel == 0 ? plan.microphoneTrackID : plan.applicationTrackID
        let present = words[track, default: []]
          .contains {
            Double($0.startMs) >= start - 500 && Double($0.startMs) <= end + 500
              && $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) == event.marker
          }
        if present {
          verified += 1
          if [0, blocks / 2, blocks - 1].contains(block) { verifiedAnchors += 1 }
        } else {
          missing.append([
            "block": block, "channel": event.channel, "startMs": start, "marker": event.marker,
          ])
        }
      }
    }
    // Report every location so a recognition gap can be distinguished from truncation.
    return [
      "applicable": true, "expected": blocks * 3, "verified": verified,
      "expectedAnchors": 9, "verifiedAnchors": verifiedAnchors,
      "startMiddleFinalSourcesPresent": verifiedAnchors == 9,
      "allMarkersPresent": missing.isEmpty, "missing": missing,
    ]
  }
}
