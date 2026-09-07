import Foundation
import TrigoContracts

public enum LocalDevelopmentError: Error {
  case invalidConfiguration, unsafeConfigurationFile, developmentVariantRequired
}

/// Explicit local-run capability. Ordinary Dev and personal connections remain HTTPS-only.
public struct LocalDevelopmentConfiguration: Sendable {
  private let bridge: LocalDevelopmentBridge
  public var worktreeId: String { bridge.worktreeId }
  public var namespaceId: String { bridge.namespaceId }
  public var ownerToken: String { bridge.ownerToken }
  public let serverURL: URL

  public init(worktreeId: String, namespaceId: String, serverURL: URL, ownerToken: String) throws {
    let bridge = LocalDevelopmentBridge(
      formatVersion: 1, worktreeId: worktreeId, namespaceId: namespaceId,
      serverURL: serverURL.absoluteString, ownerToken: ownerToken)
    _ = try Contract.encode(bridge)
    try self.init(validated: bridge, worktree: worktreeId)
  }

  private init(validated bridge: LocalDevelopmentBridge, worktree: String) throws {
    guard let serverURL = URL(string: bridge.serverURL) else {
      throw LocalDevelopmentError.invalidConfiguration
    }
    self.bridge = bridge
    self.serverURL = serverURL
    try validate(worktree: worktree)
  }

  func validate(worktree: String) throws {
    guard worktreeId == worktree,
      let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
      components.scheme == "http", components.host == "127.0.0.1",
      let port = components.port, (1024...65_535).contains(port),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil, components.path.isEmpty,
      bridge.serverURL == "http://127.0.0.1:\(port)"
    else { throw LocalDevelopmentError.invalidConfiguration }
  }

  public static func load(url: URL, worktree: String, variant: AppVariant) throws -> Self {
    guard variant == .dev else { throw LocalDevelopmentError.developmentVariantRequired }
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? 0) <= 8192,
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw LocalDevelopmentError.unsafeConfigurationFile }
    let bridge = try Contract.decode(
      LocalDevelopmentBridge.self, bytes: Data(contentsOf: url)
    ).value
    return try Self(validated: bridge, worktree: worktree)
  }
}

enum ServerTransportPolicy: Sendable {
  case httpsOnly
  case localDevelopment(LocalDevelopmentConfiguration)

  func canonicalURL(_ rawValue: String) -> URL? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if case .localDevelopment(let configuration) = self {
      guard value == configuration.serverURL.absoluteString else { return nil }
      return configuration.serverURL
    }
    guard var components = URLComponents(string: value),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil, components.path.isEmpty || components.path == "/"
    else { return nil }
    if let port = components.port, !(1...65_535).contains(port) { return nil }
    components.scheme = "https"
    components.path = ""
    return components.url
  }
}
