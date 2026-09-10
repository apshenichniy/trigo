import Foundation
import Testing

@Suite struct DailyUseProviderReceiptTests {
  @Test func absentOptionalDurationPreservesTheCompleteProviderReceipt() throws {
    // The retained Cloudflare response contains results and usage, without metadata.
    // The server consequently preserves an explicit null instead of inventing duration.
    let receipt = try decodeReceipt(duration: nil)
    try receipt.validate(byteLength: 64_044, frameCount: 16_000)
    #expect(receipt.reportedDurationSeconds == nil)
  }

  @Test func reportedDurationMustMatchTheEntireSubmittedInterval() throws {
    try decodeReceipt(duration: 1).validate(byteLength: 64_044, frameCount: 16_000)
    for duration in [0.0, 0.5, 1.001, 2.0] {
      #expect(throws: DailyUseAcceptanceFailure.self) {
        try decodeReceipt(duration: duration).validate(byteLength: 64_044, frameCount: 16_000)
      }
    }
  }

  @Test func absentDurationCannotExcusePartialOrUnobservedDelivery() throws {
    for change: [String: Any] in [
      ["deliveryWitness": "unobserved"],
      ["deliveredByteLength": 44],
      ["responseBodyComplete": false],
      ["providerHttpStatus": 500],
    ] {
      #expect(throws: DailyUseAcceptanceFailure.self) {
        try decodeReceipt(duration: nil, transportChanges: change)
          .validate(byteLength: 64_044, frameCount: 16_000)
      }
    }
    #expect(throws: DailyUseAcceptanceFailure.self) {
      try decodeReceipt(duration: nil, requestId: nil)
        .validate(byteLength: 64_044, frameCount: 16_000)
    }
  }

  @Test func uploadAcknowledgmentMatchesExactBytesAndAllowsRoundedProviderDuration() throws {
    let hash = String(repeating: "a", count: 64)
    let transport: [String: Any] = [
      "deliveryWitness": "http-upload-ack-v1", "uploadedByteLength": 64_044,
      "inputSHA256": hash, "uploadHttpStatus": 200,
      "uploadURL": "https://cdn.eu.assemblyai.com/upload/fixture",
    ]
    let receipt = try decodeReceipt(duration: 1, transportChanges: transport)
    try receipt.validate(byteLength: 64_044, frameCount: 16_000, inputSHA256: hash)
    try receipt.validate(byteLength: 64_044, frameCount: 20_000, inputSHA256: hash)
    #expect(throws: DailyUseAcceptanceFailure.self) {
      try receipt.validate(byteLength: 44, frameCount: 16_000, inputSHA256: hash)
    }
    #expect(throws: DailyUseAcceptanceFailure.self) {
      try receipt.validate(
        byteLength: 64_044,
        frameCount: 16_000,
        inputSHA256: String(repeating: "b", count: 64)
      )
    }
    #expect(throws: DailyUseAcceptanceFailure.self) {
      try receipt.validate(byteLength: 64_044, frameCount: 160_000, inputSHA256: hash)
    }
  }

  private func decodeReceipt(
    duration: Double?,
    transportChanges: [String: Any] = [:],
    requestId: String? = "controlled-provider-request"
  ) throws -> DailyUseProviderReceipt {
    var transport: [String: Any] = [
      "deliveryWitness": "consumer-eof-v1", "deliveredByteLength": 64_044,
      "responseBodyComplete": true, "providerHttpStatus": 200,
    ]
    transport.merge(transportChanges) { _, replacement in replacement }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "transport": transport,
      "providerRequestId": requestId.map { $0 as Any } ?? NSNull(),
      "reportedDurationSeconds": duration.map { $0 as Any } ?? NSNull(),
    ])
    return try JSONDecoder().decode(DailyUseProviderReceipt.self, from: bytes)
  }
}
