import Foundation
import Testing

@testable import TrigoNative

@Test func variantsCannotShareArchiveOrCredentials() throws {
  let root = URL(fileURLWithPath: "/tmp/trigo-test-\(UUID().uuidString)")
  let personal = try AppNamespace(variant: .personal, worktree: "one", support: root)
  let dev = try AppNamespace(variant: .dev, worktree: "one", support: root)
  let other = try AppNamespace(variant: .dev, worktree: "two", support: root)
  #expect(personal.archive != dev.archive)
  #expect(personal.journal != dev.journal)
  #expect(personal.preferences != dev.preferences)
  #expect(personal.connection != dev.connection)
  #expect(personal.keychainService != dev.keychainService)
  #expect(dev.archive != other.archive)
  #expect(dev.keychainService != other.keychainService)
  #expect(throws: NamespaceError.self) {
    try AppNamespace(variant: .dev, worktree: "../escape", support: root)
  }
}
