import Foundation

struct DailyUseLatencyMeasurement {
  let freshLatencyMeasurement: Bool
  let preFinishUploadMbps: Double
  let warmStatusRoundTripsMs: [Double]
  let finishToStoredMs: Double
  let finishToReadyMs: Double
  let attemptCount: Int

  var conditionsSatisfied: Bool {
    freshLatencyMeasurement && preFinishUploadMbps >= 10
      && warmStatusRoundTripsMs.count == 5
      && warmStatusRoundTripsMs.allSatisfy { $0 >= 0 && $0 <= 100 } && attemptCount == 1
  }

  var passed: Bool { conditionsSatisfied && finishToReadyMs >= 0 && finishToReadyMs <= 300_000 }

  var fields: [String: Any] {
    [
      "freshLatencyMeasurement": freshLatencyMeasurement,
      "preFinishUploadMbps": preFinishUploadMbps,
      "warmStatusRoundTripsMs": warmStatusRoundTripsMs,
      "finishToStoredMs": finishToStoredMs,
      "finishToReadyMs": finishToReadyMs,
      "attemptCount": attemptCount,
      "latencyConditionsSatisfied": conditionsSatisfied,
      "qualifiedOneHourLatencyPassed": passed,
    ]
  }

  @MainActor func verifyReadyEvidence<Result>(
    in runFolder: URL,
    verify: () async throws -> Result
  ) async throws -> Result {
    // A later provenance, marker, restore or playback assertion must not erase
    // the already observed network and lifecycle measurements.
    try writeDailyUseJSON(fields, to: runFolder.appending(path: "latency.json"))
    return try await verify()
  }
}
