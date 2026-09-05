import Foundation

public enum AppVariant: String, Sendable {
  case personal, dev
  public var bundleIdentifier: String {
    self == .personal ? "io.github.apshenichniy.trigo" : "io.github.apshenichniy.trigo.dev"
  }
  public var appName: String { self == .personal ? "Trigo" : "Trigo Dev" }
}
public enum NamespaceError: Error { case invalidWorktree }
public struct AppNamespace: Sendable {
  public let archive: URL
  public let journal: URL
  public let connection: URL
  public let preferences: String
  public let keychainService: String
  public init(variant: AppVariant, worktree: String, support: URL) throws {
    guard !worktree.isEmpty,
      worktree.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    else { throw NamespaceError.invalidWorktree }
    let namespace = variant.bundleIdentifier + (variant == .dev ? ".\(worktree)" : "")
    let root = support.appendingPathComponent(namespace, isDirectory: true)
    archive = root.appendingPathComponent("Archive", isDirectory: true)
    journal = root.appendingPathComponent("Journal", isDirectory: true)
    connection = root.appendingPathComponent("connection.json")
    preferences = namespace
    keychainService = namespace + ".connection-token"
  }
}

extension AppNamespace {
  public static func installed(bundle: Bundle = .main) throws -> AppNamespace {
    let variant: AppVariant =
      bundle.bundleIdentifier == AppVariant.dev.bundleIdentifier ? .dev : .personal
    let worktree = bundle.object(forInfoDictionaryKey: "TrigoWorktreeID") as? String ?? "local"
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return try AppNamespace(variant: variant, worktree: worktree, support: support)
  }
}
