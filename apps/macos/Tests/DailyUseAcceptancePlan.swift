import CryptoKit
import Foundation
import TrigoContracts

@testable import TrigoNative

struct DailyUseAcceptanceFailure: Error, CustomStringConvertible {
  let description: String
}

func requireDailyUse(_ condition: Bool, _ message: String) throws {
  if !condition { throw DailyUseAcceptanceFailure(description: message) }
}

func requiredDailyUse<Value>(_ value: Value?, _ message: String) throws -> Value {
  guard let value else { throw DailyUseAcceptanceFailure(description: message) }
  return value
}

struct DailyUseSource: Codable, Equatable, Sendable {
  let revision: String
  let fingerprint: String
  let dirty: Bool
}

struct DailyUseInvocation: Decodable {
  let schemaVersion: Int
  let invocationId: String
  let action: String
  let profile: String
  let directory: String
  let configuration: String
  let local: Bool
  let planSHA256: String?
  let allowPaid: Bool
  let root: String
  let source: DailyUseSource
  let configurationSHA256: String
  let apiURL: String?
  let accountID: String?
  let resultPath: String

  var durationMs: Int {
    profile == "one-hour" ? 3_600_000 : profile == "three-hour" ? 10_800_000 : 60_000
  }
  var providerSubmissions: Int { local ? 0 : profile == "three-hour" ? 4 : 2 }
  var folder: URL { URL(fileURLWithPath: directory, isDirectory: true) }
  var archive: URL { folder.appending(path: "Archive", directoryHint: .isDirectory) }

  func validate() throws {
    let repository = URL(fileURLWithPath: root, isDirectory: true)
    let expectedParent = repository.appending(path: ".local", directoryHint: .isDirectory)
    try requireDailyUse(
      schemaVersion == 1 && UUID(uuidString: invocationId)?.uuidString.lowercased() == invocationId
        && ["prepare", "run"].contains(action)
        && ["one-hour", "three-hour", "local-smoke"].contains(profile)
        && local == (profile == "local-smoke")
        && folder.deletingLastPathComponent().path == expectedParent.path
        && folder.lastPathComponent.range(
          of: "^daily-use-acceptance-[a-z0-9-]+$",
          options: .regularExpression
        ) != nil
        && repository.standardizedFileURL.resolvingSymlinksInPath().path == root
        && folder.standardizedFileURL.resolvingSymlinksInPath().path == directory
        && archive.resolvingSymlinksInPath().path == archive.standardizedFileURL.path
        && resultPath == folder.appending(path: "result-\(invocationId).json").path,
      "Invalid or non-isolated daily-use invocation."
    )
    try requireDailyUse(
      local || !source.dirty,
      "Hosted acceptance requires the committed reviewed source."
    )
    try requireDailyUse(
      Contract.hash(try Data(contentsOf: URL(fileURLWithPath: configuration)))
        == configurationSHA256,
      "The target configuration changed."
    )
    if action == "prepare" {
      try requireDailyUse(
        !allowPaid && planSHA256 == nil,
        "Preparation cannot admit provider work."
      )
    } else {
      try requireDailyUse(
        allowPaid == !local && planSHA256?.count == 64,
        "Run requires explicit admission to one prepared plan."
      )
    }
    if !local {
      let url = try requiredDailyUse(apiURL, "The Dev API URL is missing.")
      let config =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: URL(fileURLWithPath: configuration))
        ) as? [String: Any]
      try requireDailyUse(
        config?["stage"] as? String == "dev"
          && config?["profile"] as? String == "trigo-cloud-dev"
          && config?["apiUrl"] as? String == url
          && config?["accountId"] as? String == accountID
          && accountID?.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
          && ServerTransportPolicy.httpsOnly.canonicalURL(url)?.absoluteString == url,
        "Hosted acceptance requires the exact validated Dev target."
      )
    }
  }
}

struct DailyUsePlan: Codable, Sendable {
  let schemaVersion: Int
  let kind: String
  let profile: String
  let source: DailyUseSource
  let configurationSHA256: String
  let apiURL: String
  let archiveID: String
  let callID: String
  let masterID: String
  let microphoneTrackID: String
  let applicationTrackID: String
  let manifestID: String
  let uploadID: String
  let finalizeOperationID: String
  let transcriptionOperationID: String
  let revisionID: String
  let durationMs: Int
  let byteLength: Int
  let templateSHA256: String
  let templateMetadataSHA256: String
  let masterSHA256: String
  let sourceStatesSHA256: String
  let registrationSHA256: String
  let maximumProviderSubmissions: Int
  let preparedAt: String

  func validate(
    invocation: DailyUseInvocation,
    apiURL: URL,
    archiveID: String,
    template: DailyUseTemplate
  ) throws {
    let ids = [
      self.archiveID, callID, masterID, microphoneTrackID, applicationTrackID, manifestID,
      uploadID, finalizeOperationID, transcriptionOperationID, revisionID,
    ]
    try requireDailyUse(
      ids.allSatisfy { UUID(uuidString: $0)?.uuidString.lowercased() == $0 }
        && Set(ids).count == ids.count
        && schemaVersion == 1 && kind == "synthetic-native-daily-use-v1"
        && profile == invocation.profile && source == invocation.source
        && configurationSHA256 == invocation.configurationSHA256
        && self.apiURL == apiURL.absoluteString && self.archiveID == archiveID
        && durationMs == invocation.durationMs && byteLength == 68 + durationMs * 64
        && maximumProviderSubmissions == invocation.providerSubmissions
        && templateSHA256 == template.sha256
        && templateMetadataSHA256 == template.metadataSHA256
        && masterSHA256 == template.masterHash(durationMs: durationMs)
        && sourceStatesSHA256 == Contract.hash(Data(repeating: 0, count: durationMs / 2))
        && transcriptionOperationID
          == synchronizationIdentity("trigo-initial-transcription:\(archiveID):\(callID)")
        && revisionID == synchronizationIdentity("trigo-initial-revision:\(archiveID):\(callID)"),
      "The prepared call, source, media or provider admission does not match this invocation."
    )
  }
}

struct DailyUseTemplate: Sendable {
  let bytes: Data
  let sha256: String
  let metadataSHA256: String
  let events: [DailyUseSpeechEvent]

  init(folder: URL) throws {
    let file = folder.appending(path: "template.caf")
    try requireDailyUse(
      try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]).fileSize == 3_840_068
        && file.resolvingSymlinksInPath() == file,
      "The acceptance template must be the bounded owned one-minute CAF."
    )
    bytes = try Data(contentsOf: file)
    sha256 = Contract.hash(bytes)
    let metadataFile = folder.appending(path: "template.caf.json")
    try requireDailyUse(
      (try metadataFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32_768
        && metadataFile.resolvingSymlinksInPath() == metadataFile,
      "The template metadata is not bounded owned evidence."
    )
    let metadataBytes = try Data(contentsOf: metadataFile)
    metadataSHA256 = Contract.hash(metadataBytes)
    let metadata = try JSONDecoder().decode(DailyUseTemplateMetadata.self, from: metadataBytes)
    events = metadata.events
    try requireDailyUse(
      bytes.prefix(68) == MediaMasterProfile.header
        && metadata.schemaVersion == 1 && metadata.kind == "controlled-synthetic-speech"
        && metadata.language == "en" && metadata.sha256 == sha256
        && metadata.layout == "twenty-second-blocks-start-middle-final-v1"
        && metadata.durationMs == 60_000 && metadata.byteLength == bytes.count
        && events.count == 9,
      "The controlled speech template or its exact bytes changed."
    )
    for block in 0..<3 {
      let selected = events.filter { $0.block == block }.sorted { $0.startMs < $1.startMs }
      try requireDailyUse(
        selected.count == 3
          && selected.map(\.channel) == [0, 1, 1]
          && selected.map(\.startMs) == [1000, 5500, 12000].map { Double(block * 20_000 + $0) }
          && selected.allSatisfy {
            $0.marker == ["alpha", "bravo", "charlie"][block]
              && $0.role == ($0.channel == 0 ? "microphone" : "application")
              && $0.endMs > $0.startMs && $0.endMs <= Double((block + 1) * 20_000)
          },
        "The template speech events do not match the controlled source layout."
      )
    }
  }

  func sourceSecond(_ second: Int, durationMs: Int) -> Int {
    let blocks = durationMs / 20_000
    let block = second / 20
    let sourceBlock = block == blocks - 1 ? 2 : block == blocks / 2 ? 1 : 0
    return sourceBlock * 20 + second % 20
  }

  func pcmSecond(_ second: Int, durationMs: Int) -> Data {
    let offset = 68 + sourceSecond(second, durationMs: durationMs) * 64_000
    return bytes.subdata(in: offset..<(offset + 64_000))
  }

  func samples(second: Int, durationMs: Int) -> [Int16] {
    let data = pcmSecond(second, durationMs: durationMs)
    return data.withUnsafeBytes { buffer in
      (0..<32_000)
        .map {
          Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
        }
    }
  }

  func sample(frame: Int, channel: Int, durationMs: Int) -> Int16 {
    let second = frame / 16_000
    let offset =
      68 + sourceSecond(second, durationMs: durationMs) * 64_000
      + (frame % 16_000) * 4 + channel * 2
    return bytes.withUnsafeBytes {
      Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))
    }
  }

  func masterHash(durationMs: Int) -> String {
    var digest = SHA256()
    digest.update(data: bytes.prefix(68))
    for second in 0..<(durationMs / 1000) {
      digest.update(data: pcmSecond(second, durationMs: durationMs))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

struct DailyUseSpeechEvent: Decodable, Sendable {
  let block: Int
  let marker: String
  let role: String
  let channel: Int
  let startMs: Double
  let endMs: Double
}

private struct DailyUseTemplateMetadata: Decodable {
  let schemaVersion: Int
  let kind: String
  let language: String
  let sha256: String
  let layout: String
  let durationMs: Int
  let byteLength: Int
  let events: [DailyUseSpeechEvent]
}

func dailyUseTimestamp() -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date())
}

func writeDailyUseJSON(_ object: [String: Any], to url: URL) throws {
  try writeDailyUseBytes(
    JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
    to: url
  )
}

func writeDailyUseBytes(_ bytes: Data, to url: URL) throws {
  try requireDailyUse(
    url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
    "Acceptance evidence cannot follow symlinks."
  )
  if FileManager.default.fileExists(atPath: url.path) {
    try requireDailyUse(
      try Data(contentsOf: url) == bytes,
      "Refusing to replace different retained acceptance evidence."
    )
    return
  }
  try bytes.write(to: url, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

actor DailyUseCredentials: CredentialStoring {
  private var values: [String: String] = [:]
  func load(account: String) -> String? { values[account] }
  func save(token: String, account: String) { values[account] = token }
  func delete(account: String) { values.removeValue(forKey: account) }
}
