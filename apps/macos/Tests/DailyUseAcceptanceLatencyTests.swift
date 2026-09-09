import Foundation
import Testing

@Suite struct DailyUseAcceptanceLatencyTests {
  @Test @MainActor func downstreamFailureRetainsMeasuredLatencyWithoutCompletion() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let measurement = sample()
    do {
      try await measurement.verifyReadyEvidence(in: folder) {
        throw DailyUseAcceptanceFailure(description: "Controlled downstream provenance failure.")
      }
      Issue.record("The controlled evidence failure was swallowed.")
    } catch let failure as DailyUseAcceptanceFailure {
      #expect(failure.description == "Controlled downstream provenance failure.")
    }
    let retained = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: folder.appending(path: "latency.json"))
      ) as? [String: Any]
    )
    #expect(retained["warmStatusRoundTripsMs"] as? [Double] == [20, 30, 40, 50, 60])
    #expect(retained["preFinishUploadMbps"] as? Double == 20)
    #expect(retained["finishToReadyMs"] as? Double == 75_000)
    #expect(retained["qualifiedOneHourLatencyPassed"] as? Bool == true)
    #expect(retained["hostedAcceptancePassed"] == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "completed.json").path))
  }

  @Test func incompleteOrUnqualifiedMeasurementsCannotPass() {
    #expect(sample().passed)
    #expect(!sample(fresh: false).passed)
    #expect(!sample(upload: 9.99).passed)
    #expect(!sample(roundTrips: [20, 30, 40, 50]).passed)
    #expect(!sample(roundTrips: [20, 30, 40, 50, 100.01]).passed)
    #expect(!sample(attempts: 2).passed)
    #expect(!sample(ready: 300_001).passed)
  }

  private func sample(
    fresh: Bool = true,
    upload: Double = 20,
    roundTrips: [Double] = [20, 30, 40, 50, 60],
    attempts: Int = 1,
    ready: Double = 75_000
  ) -> DailyUseLatencyMeasurement {
    .init(
      freshLatencyMeasurement: fresh,
      preFinishUploadMbps: upload,
      warmStatusRoundTripsMs: roundTrips,
      finishToStoredMs: 20_000,
      finishToReadyMs: ready,
      attemptCount: attempts
    )
  }
}
