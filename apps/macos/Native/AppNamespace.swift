import Foundation

public enum AppVariant: String, Sendable {
  case personal, dev
  public var bundleIdentifier: String {
    self == .personal ? "io.github.apshenichniy.trigo" : "io.github.apshenichniy.trigo.dev"
  }
  public var appName: String { self == .personal ? "Trigo" : "Trigo Dev" }

  /// Unknown bundles, including UI fixtures, must never inherit Personal credentials.
  public static func installed(bundleIdentifier: String?) throws -> Self {
    switch bundleIdentifier {
    case AppVariant.personal.bundleIdentifier: .personal
    case AppVariant.dev.bundleIdentifier: .dev
    default: throw NamespaceError.unsupportedBundle
    }
  }
}
public enum NamespaceError: Error {
  case invalidWorktree, unsupportedBundle, fixtureRequiresAdapters, variantMismatch
}
public struct AppNamespace: Sendable {
  public let variant: AppVariant?
  public let fixtureIdentifier: String?
  public let localDevelopment: LocalDevelopmentConfiguration?
  public let archive: URL
  public let journal: URL
  public let connection: URL
  public let preferences: String
  public let keychainService: String
  public init(
    variant: AppVariant,
    worktree: String,
    support: URL,
    localDevelopment: LocalDevelopmentConfiguration? = nil
  ) throws {
    guard !worktree.isEmpty,
      worktree.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    else { throw NamespaceError.invalidWorktree }
    if let localDevelopment {
      guard variant == .dev else { throw LocalDevelopmentError.developmentVariantRequired }
      try localDevelopment.validate(worktree: worktree)
    }
    self.localDevelopment = localDevelopment
    self.variant = variant
    self.fixtureIdentifier = nil
    let namespace =
      variant.bundleIdentifier + (variant == .dev ? ".\(worktree)" : "")
      + (localDevelopment.map { ".local.\($0.namespaceId)" } ?? "")
    let root = support.appendingPathComponent(namespace, isDirectory: true)
    archive = root.appendingPathComponent("Archive", isDirectory: true)
    journal = root.appendingPathComponent("Journal", isDirectory: true)
    connection = root.appendingPathComponent("connection.json")
    preferences = namespace
    keychainService = namespace + ".connection-token"
  }

  /// An explicit, per-run fixture identity. No installed factory accepts this namespace.
  public init(fixtureBundleIdentifier: String, runID: String, support: URL) throws {
    let prefix = "io.github.apshenichniy.trigo.fixture."
    guard fixtureBundleIdentifier.hasPrefix(prefix),
      fixtureBundleIdentifier.dropFirst(prefix.count)
        .range(
          of: "^[a-zA-Z0-9_-]+$",
          options: .regularExpression
        ) != nil
    else { throw NamespaceError.unsupportedBundle }
    guard runID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
      throw NamespaceError.invalidWorktree
    }
    variant = nil
    fixtureIdentifier = fixtureBundleIdentifier
    localDevelopment = nil
    let identity = fixtureBundleIdentifier + "." + runID
    let root = support.appendingPathComponent(identity, isDirectory: true)
    archive = root.appendingPathComponent("Archive", isDirectory: true)
    journal = root.appendingPathComponent("Journal", isDirectory: true)
    connection = root.appendingPathComponent("connection.json")
    preferences = identity
    keychainService = identity + ".connection-token"
  }

  public func requireInstalledVariant(_ expected: AppVariant) throws {
    guard fixtureIdentifier == nil else { throw NamespaceError.fixtureRequiresAdapters }
    guard variant == expected else { throw NamespaceError.variantMismatch }
  }
}

extension AppNamespace {
  public static func installed(bundle: Bundle = .main) throws -> AppNamespace {
    let variant = try AppVariant.installed(bundleIdentifier: bundle.bundleIdentifier)
    let worktree = bundle.object(forInfoDictionaryKey: "TrigoWorktreeID") as? String ?? "local"
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0
      ]
    var local: LocalDevelopmentConfiguration?
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--local-config") {
      guard arguments.indices.contains(index + 1) else {
        throw LocalDevelopmentError.invalidConfiguration
      }
      local = try LocalDevelopmentConfiguration.load(
        url: URL(fileURLWithPath: arguments[index + 1]),
        worktree: worktree,
        variant: variant
      )
    }
    return try AppNamespace(
      variant: variant,
      worktree: worktree,
      support: support,
      localDevelopment: local
    )
  }
}
