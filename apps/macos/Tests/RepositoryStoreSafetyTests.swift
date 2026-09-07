import Foundation
import SQLite3
import Testing

@testable import TrigoNative

@Test(arguments: [
  "version", "prior-capture-schema", "application", "schema", "foreign", "copied-root", "corrupt",
])
func repositoryUnsupportedForeignAndCorruptStoresRemainUntouched(kind: String) async throws {
  let root = repositoryRoot("unsupported")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try await seedRepositoryCall(root: root)
  repository = nil
  #expect(repository == nil)
  var target = root
  let url = root.appendingPathComponent(SQLiteDatabase.filename)
  if kind == "version" { try sqliteFixtureSQL(url, "PRAGMA user_version=99") }
  if kind == "prior-capture-schema" { try sqliteFixtureSQL(url, "PRAGMA user_version=1") }
  if kind == "application" { try sqliteFixtureSQL(url, "PRAGMA application_id=123") }
  if kind == "schema" { try sqliteFixtureSQL(url, "CREATE TABLE unexpected(value TEXT)") }
  if kind == "corrupt" { try Data("not a SQLite database".utf8).write(to: url) }
  if kind == "copied-root" {
    target = root.appendingPathComponent("copied")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.copyItem(
      at: url, to: target.appendingPathComponent(SQLiteDatabase.filename))
  }
  let targetURL = target.appendingPathComponent(SQLiteDatabase.filename)
  let before = try Data(contentsOf: targetURL)
  #expect(throws: LocalPersistenceError.self) {
    try LocalRepository(
      root: target,
      archiveID: kind == "foreign" ? UUID().uuidString.lowercased() : repositoryArchiveID)
  }
  #expect(try Data(contentsOf: targetURL) == before)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: target.path).filter {
      $0.hasPrefix(SQLiteDatabase.filename)
    } == [SQLiteDatabase.filename])
}

@Test(arguments: ["root", "parent", "database", "journal", "wal", "shm", "hard-link"])
func repositoryLinkedStoresAreRejectedWithoutFollowingThem(kind: String) async throws {
  let fixture = repositoryRoot("linked")
  defer { try? FileManager.default.removeItem(at: fixture) }
  let root = fixture.appendingPathComponent("archive")
  let foreign = fixture.appendingPathComponent("foreign")
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
  let bytes = Data("retained foreign evidence".utf8)
  let foreignFile = foreign.appendingPathComponent("evidence")
  try bytes.write(to: foreignFile)
  var target = root
  if kind == "root" || kind == "parent" {
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: foreign)
    if kind == "parent" { target = root.appendingPathComponent("nested") }
  } else {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let suffix = [
      "database": "", "journal": "-journal", "wal": "-wal", "shm": "-shm", "hard-link": "",
    ][kind]!
    let linked = root.appendingPathComponent(SQLiteDatabase.filename + suffix)
    if kind == "hard-link" {
      try FileManager.default.linkItem(at: foreignFile, to: linked)
    } else {
      try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreignFile)
    }
  }
  #expect(throws: LocalPersistenceError.self) {
    try LocalRepository(root: target, archiveID: repositoryArchiveID)
  }
  #expect(try Data(contentsOf: foreignFile) == bytes)
  #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path) == ["evidence"])
}

@Test func repositoryCleanTestCutoverUsesANewExplicitNamespaceAndPreservesLegacyEvidence()
  async throws
{
  let fixture = repositoryRoot("cutover")
  defer { try? FileManager.default.removeItem(at: fixture) }
  let legacy = fixture.appendingPathComponent("legacy-test")
  try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
  let evidence = legacy.appendingPathComponent("call.json")
  let bytes = Data("old test evidence".utf8)
  try bytes.write(to: evidence)
  #expect(throws: LocalPersistenceError.self) {
    try LocalRepository(root: legacy, archiveID: repositoryArchiveID)
  }
  let clean = fixture.appendingPathComponent("explicit-new-test")
  let repository = try await seedRepositoryCall(root: clean)
  #expect(try await repository.calls().count == 1)
  #expect(try Data(contentsOf: evidence) == bytes)
  #expect(try FileManager.default.contentsOfDirectory(atPath: legacy.path) == ["call.json"])
  let another = try LocalRepository(
    root: fixture.appendingPathComponent("another-test"), archiveID: repositoryArchiveID)
  #expect(try await another.calls().isEmpty)
}

@Test func repositoryBusyCommitRollsBackAndLeavesTheConnectionReusable() async throws {
  let root = repositoryRoot("busy-commit")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  let reader = try sqliteFixtureOpen(root.appendingPathComponent(SQLiteDatabase.filename))
  defer { sqlite3_close(reader) }
  try sqliteFixtureExec(reader, "BEGIN; SELECT count(*) FROM calls")
  await #expect(throws: LocalPersistenceError.self) {
    try await repository.updateLifecycle(callID: repositoryCallID) {
      $0.upload = .init(state: .uploading)
    }
  }
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.upload.state == .pending)
  try sqliteFixtureExec(reader, "ROLLBACK")
  _ = try await repository.updateLifecycle(callID: repositoryCallID) {
    $0.upload = .init(state: .uploading)
  }
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.upload.state == .uploading)
}

@Test func repositoryFullErrorRollsBackJointRowsAndKeepsTheConnectionReusable() async throws {
  let root = repositoryRoot("full")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  let database = repository.database
  #expect(throws: LocalPersistenceError.self) {
    try database.access {
      let pages = try database.scalarInt("PRAGMA page_count")
      _ = try database.scalarInt("PRAGMA max_page_count=\(pages)")
      try database.transaction {
        try database.execute("UPDATE lifecycle SET upload='uploading'")
        try database.execute(
          "INSERT INTO document_chunks SELECT hash,999,zeroblob(262144) FROM documents LIMIT 1")
      }
    }
  }
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.upload.state == .pending)
  try database.access { _ = try database.scalarInt("PRAGMA max_page_count=1073741823") }
  _ = try await repository.updateLifecycle(callID: repositoryCallID) {
    $0.upload = .init(state: .stored)
  }
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.upload.state == .stored)
}

func sqliteFixtureOpen(_ url: URL) throws -> OpaquePointer {
  var database: OpaquePointer?
  let code = sqlite3_open_v2(
    try canonicalRepositoryRoot(url).path, &database,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
  guard code == SQLITE_OK, let database else { throw RepositoryInjectedFailure() }
  return database
}

func sqliteFixtureExec(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw LocalPersistenceError.sqlite(
      code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
  }
}

func sqliteFixtureSQL(_ url: URL, _ sql: String) throws {
  let database = try sqliteFixtureOpen(url)
  defer { sqlite3_close(database) }
  try sqliteFixtureExec(database, sql)
}
