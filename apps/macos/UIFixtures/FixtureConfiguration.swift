import Foundation

enum FixtureScenario: String, Codable {
  case empty, setup, denied
}

struct FixtureConfiguration: Codable {
  let schemaVersion: Int
  let runID: String
  let scenario: FixtureScenario
  let clock: String
  let timeZone: String
  static let bundleID = "io.github.apshenichniy.trigo.fixture.desktop"
  static let archiveID = "00000000-0000-4000-8000-000000000072"

  static func load() throws -> (Self, URL) {
    let arguments = ProcessInfo.processInfo.arguments
    guard Bundle.main.bundleIdentifier == bundleID,
      let index = arguments.firstIndex(of: "--fixture-config"),
      arguments.indices.contains(index + 1)
    else { throw FixtureFailure.invalidConfiguration }
    let file = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    let root = file.deletingLastPathComponent().resolvingSymlinksInPath()
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    // XCTest's runner has its own sandboxed temporary directory. The fixture
    // accepts only that exact runner's temp root or the current user's temp root.
    let runnerTemporary = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/\(bundleID).uitests.xctrunner/Data/tmp")
      .resolvingSymlinksInPath()
    guard [temporary, runnerTemporary].contains(root.deletingLastPathComponent()),
      root.lastPathComponent.hasPrefix("trigo-ui-fixture-"),
      file.lastPathComponent == "configuration.json",
      file.resolvingSymlinksInPath() == root.appendingPathComponent("configuration.json")
    else { throw FixtureFailure.invalidConfiguration }
    let bytes = try Data(contentsOf: file)
    guard bytes.count <= 4096 else { throw FixtureFailure.invalidConfiguration }
    let value = try JSONDecoder().decode(Self.self, from: bytes)
    guard value.schemaVersion == 1, UUID(uuidString: value.runID) != nil,
      ISO8601DateFormatter().date(from: value.clock) != nil,
      TimeZone(identifier: value.timeZone) != nil
    else { throw FixtureFailure.invalidConfiguration }
    return (value, root)
  }
}

enum FixtureFailure: Error { case invalidConfiguration, forbiddenAdapter, invalidAudio }
