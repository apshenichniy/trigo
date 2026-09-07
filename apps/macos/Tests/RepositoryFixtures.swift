import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

let repositoryArchiveID = "00000000-0000-4000-8000-000000000012"
let repositoryCallID = "00000000-0000-4000-8000-000000000001"

func repositoryFixture(_ name: String) throws -> Data {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(
      "packages/contracts/fixtures"
    )
  return try Data(contentsOf: root.appendingPathComponent(name))
}

@discardableResult
func seedRepositoryCall(
  root: URL,
  archiveID: String = repositoryArchiveID,
  finalized: Bool = false
)
  async throws -> LocalRepository
{
  let repository = try LocalRepository(root: root, archiveID: archiveID)
  var call =
    try Contract.decode(
      CallDocument.self,
      bytes: repositoryFixture(finalized ? "call.json" : "valid-recording.json")
    )
    .value
  call.archiveId = archiveID
  call.documentVersion = 1
  call.audioManifest = nil
  call.revisions = []
  call.activeRevisionId = nil
  call.speakerNames = [:]
  _ = try await repository.publishManifest(Contract.encode(call))
  return repository
}

func repositoryRoot(_ label: String = "") -> URL {
  try! canonicalRepositoryRoot(
    FileManager.default.temporaryDirectory.appendingPathComponent("trigo-sqlite-\(label)-\(UUID())")
  )
}

func repositorySession(
  _ root: URL,
  archiveID: String = repositoryArchiveID
) throws
  -> CaptureArchiveSession
{
  try .allocate(
    root: root,
    archiveID: archiveID,
    source: .init(
      applicationName: "Fixture",
      bundleID: "fixture.sqlite",
      processID: 123,
      windowID: 456,
      windowTitle: nil,
      processLaunchDate: Date(timeIntervalSince1970: 100)
    ),
    microphone: .init(id: "fixture-mic", name: "Fixture microphone"),
    startedAt: Date(timeIntervalSince1970: 1000)
  )
}

func repositoryIntent(
  callID: String = repositoryCallID,
  kind: OperationKind = .importRevision,
  payload: Data = Data()
) -> OperationIntent {
  .init(
    operationID: UUID().uuidString.lowercased(),
    archiveID: repositoryArchiveID,
    callID: callID,
    kind: kind,
    payload: payload
  )
}

struct RepositoryInjectedFailure: Error {}

final class RepositoryFault: @unchecked Sendable {
  private let lock = NSLock()
  let target: PersistenceInterruptionPoint
  private var fired = false
  init(_ target: PersistenceInterruptionPoint) { self.target = target }
  func callAsFunction(_ point: PersistenceInterruptionPoint) throws {
    try lock.withLock {
      if point == target && !fired {
        fired = true
        throw RepositoryInjectedFailure()
      }
    }
  }
}
