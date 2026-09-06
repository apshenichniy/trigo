import Darwin
import Foundation
import SQLite3

enum SQLValue: Sendable, Equatable {
  case null
  case text(String)
  case integer(Int64)
  case real(Double)
  case blob(Data)
  static func string(_ value: String?) -> Self { value.map(Self.text) ?? .null }
  static func int(_ value: Int?) -> Self { value.map { .integer(Int64($0)) } ?? .null }
}

struct SQLRow {
  let values: [SQLValue]
  func string(_ index: Int) throws -> String {
    guard case .text(let value) = values[index] else { throw invalidRow() }
    return value
  }
  func optionalString(_ index: Int) throws -> String? {
    values[index] == .null ? nil : try string(index)
  }
  func integer(_ index: Int) throws -> Int64 {
    guard case .integer(let value) = values[index] else { throw invalidRow() }
    return value
  }
  func int(_ index: Int) throws -> Int { Int(try integer(index)) }
  func optionalInt(_ index: Int) throws -> Int? {
    values[index] == .null ? nil : try int(index)
  }
  func real(_ index: Int) throws -> Double {
    guard case .real(let value) = values[index] else { throw invalidRow() }
    return value
  }
  func data(_ index: Int) throws -> Data {
    guard case .blob(let value) = values[index] else { throw invalidRow() }
    return value
  }
}

func invalidRow() -> LocalPersistenceError { .invalidStoredDocument("Invalid SQLite row") }

/// One connection and one scheduler per namespace in this process. All SQL access goes
/// through this owner, including reads. Each admitted unit releases its lock before any
/// validation, serialization, media, credentials, network effect, or suspension.
final class SQLiteDatabase: @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [String: WeakDatabase] = [:]
  private let condition = NSCondition()
  private var busy = false
  private var waitingCapture = 0
  private var poisoned = false
  private var handle: OpaquePointer?
  let root: URL
  let archiveID: String
  static let filename = "archive.sqlite3"
  static let applicationID = 0x5452_474f

  static func open(root: URL, archiveID: String) throws -> SQLiteDatabase {
    try requireCanonicalIdentifier(archiveID)
    try requireSafePath(root, directory: true, mayBeAbsent: true)
    let canonical = try canonicalRepositoryRoot(root)
    registryLock.lock()
    defer { registryLock.unlock() }
    if let existing = registry[canonical.path]?.value {
      guard existing.archiveID == archiveID else {
        throw LocalPersistenceError.archiveIdentityMismatch(
          expected: existing.archiveID, actual: archiveID)
      }
      try existing.checkPaths()
      return existing
    }
    let database = try SQLiteDatabase(root: canonical, archiveID: archiveID)
    registry[canonical.path] = WeakDatabase(database)
    registry = registry.filter { $0.value.value != nil }
    return database
  }

  private init(root: URL, archiveID: String) throws {
    self.root = root
    self.archiveID = archiveID
    let files = FileManager.default
    try files.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try checkPaths()
    let url = root.appendingPathComponent(Self.filename)
    let existed = files.fileExists(atPath: url.path)
    if !existed {
      guard try files.contentsOfDirectory(atPath: root.path).isEmpty else {
        throw LocalPersistenceError.unsupportedStore(
          "A nonempty archive requires explicit test cutover")
      }
    }
    if existed {
      try openHandle(url, flags: SQLITE_OPEN_READONLY)
      do {
        try validateExistingStore()
      } catch LocalPersistenceError.sqlite(let code, _) where code == SQLITE_READONLY | (3 << 8) {
        // READONLY cannot perform hot-journal recovery. Validate a disposable recovered
        // copy first, so a foreign/unsupported/corrupt source is never mutated to inspect it.
        sqlite3_close(handle)
        handle = nil
        try validateRecoveredCopy(url)
      } catch {
        sqlite3_close(handle)
        handle = nil
        throw error
      }
      sqlite3_close(handle)
      handle = nil
    } else {
      let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else {
        throw LocalPersistenceError.io("Cannot exclusively create SQLite archive")
      }
      Darwin.close(fd)
    }
    do {
      try openHandle(url, flags: SQLITE_OPEN_READWRITE)
      try execute("PRAGMA fullfsync=ON")
      try execute("PRAGMA synchronous=EXTRA")
      if existed { try validateExistingStore() }
      // DELETE avoids the version-dependent WAL reset race and checkpoint ownership entirely.
      guard try scalarString("PRAGMA journal_mode=DELETE") == "delete" else { throw invalidRow() }
      try execute("PRAGMA synchronous=EXTRA")
      try execute("PRAGMA fullfsync=ON")
      try execute("PRAGMA foreign_keys=ON")
      try execute("PRAGMA trusted_schema=OFF")
      try execute("PRAGMA cache_size=-4096")
      guard try scalarInt("PRAGMA synchronous") == 3,
        try scalarInt("PRAGMA fullfsync") == 1,
        try scalarInt("PRAGMA foreign_keys") == 1,
        try scalarInt("PRAGMA trusted_schema") == 0
      else {
        throw LocalPersistenceError.unsupportedStore(
          "Required SQLite durability pragmas unavailable")
      }
      if !existed {
        try transaction {
          for statement in repositorySchema { try execute(statement) }
          try execute(
            "INSERT INTO repository_identity VALUES (?, ?)", [.text(archiveID), .text(root.path)])
          try execute("PRAGMA application_id=\(Self.applicationID)")
          try execute("PRAGMA user_version=1")
        }
      }
    } catch {
      sqlite3_close(handle)
      handle = nil
      throw error
    }
  }

  deinit { sqlite3_close(handle) }

  private func validateExistingStore() throws {
    guard try scalarInt("PRAGMA application_id") == Self.applicationID,
      try scalarInt("PRAGMA user_version") == 1,
      try scalarString("PRAGMA journal_mode") == "delete"
    else {
      throw LocalPersistenceError.unsupportedStore("Unsupported SQLite identity, schema or journal")
    }
    let identity = try rows("SELECT archive_id, root FROM repository_identity")
    guard identity.count == 1, try identity[0].string(1) == root.path else {
      throw LocalPersistenceError.unsupportedStore("Repository namespace differs")
    }
    let storedID = try identity[0].string(0)
    guard storedID == archiveID else {
      throw LocalPersistenceError.archiveIdentityMismatch(expected: archiveID, actual: storedID)
    }
    func normalized(_ sql: String) -> String {
      sql.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let actual = try rows("SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL").map {
      normalized(try $0.string(0))
    }
    guard Set(actual) == Set(repositorySchema.map(normalized)) else {
      throw LocalPersistenceError.unsupportedStore(
        "SQLite schema does not match its declared version")
    }
    guard try scalarString("PRAGMA quick_check") == "ok",
      try rows("PRAGMA foreign_key_check").isEmpty
    else {
      throw LocalPersistenceError.invalidStoredDocument("SQLite integrity check failed")
    }
  }

  private func validateRecoveredCopy(_ source: URL) throws {
    let files = FileManager.default
    let temporary = try canonicalRepositoryRoot(
      files.temporaryDirectory.appendingPathComponent("trigo-sqlite-preflight-\(UUID())"))
    try files.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: temporary) }
    let originals = [source, root.appendingPathComponent(Self.filename + "-journal")]
    let fingerprints = try originals.map(fileFingerprint)
    for original in originals {
      try requireSafePath(original, directory: false)
      let copy = temporary.appendingPathComponent(original.lastPathComponent)
      try files.copyItem(at: original, to: copy)
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
    }
    try openHandle(temporary.appendingPathComponent(Self.filename), flags: SQLITE_OPEN_READWRITE)
    do {
      try execute("PRAGMA fullfsync=ON")
      try execute("PRAGMA synchronous=EXTRA")
      try validateExistingStore()
    } catch {
      sqlite3_close(handle)
      handle = nil
      throw error
    }
    sqlite3_close(handle)
    handle = nil
    guard try originals.map(fileFingerprint) == fingerprints else {
      throw LocalPersistenceError.concurrentMutation
    }
    try checkPaths()
  }

  func access<T>(capture: Bool = false, _ body: () throws -> T) throws -> T {
    condition.lock()
    if capture { waitingCapture += 1 }
    while busy || (!capture && waitingCapture > 0) { condition.wait() }
    if capture { waitingCapture -= 1 }
    busy = true
    condition.unlock()
    defer {
      condition.lock()
      busy = false
      condition.broadcast()
      condition.unlock()
    }
    guard !poisoned else {
      throw LocalPersistenceError.io("SQLite rollback failed; reopen required")
    }
    return try body()
  }

  func transaction<T>(
    interruption: PersistenceInterruption = { _ in }, _ body: () throws -> T
  ) throws -> T {
    try execute("BEGIN IMMEDIATE")
    let result: T
    do {
      result = try body()
      try interruption(.beforeRepositoryCommit)
      try execute("COMMIT")
    } catch {
      // BUSY at COMMIT leaves the transaction active. I/O errors may have rolled it back.
      if sqlite3_get_autocommit(handle) == 0 {
        do { try execute("ROLLBACK") } catch { poisoned = true }
      }
      throw error
    }
    // A thrown post-commit hook is deliberately an uncertain outcome, never a rollback.
    try interruption(.afterRepositoryCommit)
    return result
  }

  func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var result: [SQLRow] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW else { throw failure(code) }
      let values = try (0..<sqlite3_column_count(statement)).map { index -> SQLValue in
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
          let count = Int(sqlite3_column_bytes(statement, index))
          guard count <= 4096 else { throw invalidRow() }
          let bytes = UnsafeBufferPointer(
            start: sqlite3_column_text(statement, index), count: count)
          return .text(String(decoding: bytes, as: UTF8.self))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, index))
          guard count <= 256 * 1024 else { throw invalidRow() }
          return .blob(
            count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count))
        default: return .null
        }
      }
      result.append(SQLRow(values: values))
    }
  }

  func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE else { throw failure(code) }
  }

  func scalarInt(_ sql: String) throws -> Int { try rows(sql).first.map { try $0.int(0) } ?? -1 }
  func scalarString(_ sql: String) throws -> String {
    try rows(sql).first.map { try $0.string(0) } ?? ""
  }

  private func openHandle(_ url: URL, flags: Int32) throws {
    let code = sqlite3_open_v2(
      url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
    guard code == SQLITE_OK else { throw failure(code) }
    sqlite3_extended_result_codes(handle, 1)
    // External writers are unsupported while the app owns its instance lease. Still fail
    // promptly and truthfully if one contends, instead of stalling capture indefinitely.
    sqlite3_busy_timeout(handle, 250)
  }

  private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else { throw failure(code) }
    do {
      guard sqlite3_bind_parameter_count(statement) == bindings.count else { throw invalidRow() }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      for (offset, value) in bindings.enumerated() {
        let index = Int32(offset + 1)
        let code: Int32
        switch value {
        case .null: code = sqlite3_bind_null(statement, index)
        case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
        case .real(let value): code = sqlite3_bind_double(statement, index, value)
        case .text(let value):
          guard value.utf8.count <= 4096 else { throw invalidRow() }
          code = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient)
          }
        case .blob(let value):
          code =
            value.isEmpty
            ? sqlite3_bind_zeroblob(statement, index, 0)
            : value.withUnsafeBytes {
              sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), transient)
            }
        }
        guard code == SQLITE_OK else { throw failure(code) }
      }
      return statement
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }

  private func failure(_ code: Int32) -> LocalPersistenceError {
    .sqlite(
      code: code,
      message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite")
  }

  private func checkPaths() throws {
    try requireSafePath(root, directory: true)
    for suffix in ["", "-journal", "-wal", "-shm"] {
      try requireSafePath(
        root.appendingPathComponent(Self.filename + suffix), directory: false, mayBeAbsent: true)
    }
  }
}

private final class WeakDatabase {
  weak var value: SQLiteDatabase?
  init(_ value: SQLiteDatabase) { self.value = value }
}

func requireSafePath(_ url: URL, directory: Bool, mayBeAbsent: Bool = false) throws {
  var info = stat()
  if lstat(url.path, &info) != 0 {
    if mayBeAbsent && errno == ENOENT { return }
    throw LocalPersistenceError.unsafeStore(url.lastPathComponent)
  }
  let expected = directory ? S_IFDIR : S_IFREG
  guard info.st_mode & S_IFMT == expected, directory || info.st_nlink == 1 else {
    throw LocalPersistenceError.unsafeStore(url.lastPathComponent)
  }
}

private func requireSafeAncestors(_ url: URL) throws {
  var current = url.standardizedFileURL
  while current.path != "/" {
    var info = stat()
    if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
      // macOS's system aliases are outside the application namespace.
      let aliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
      let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
      guard let expected = aliases[current.path],
        destination == expected || "/" + destination == expected
      else {
        throw LocalPersistenceError.unsafeStore(current.lastPathComponent)
      }
    }
    current.deleteLastPathComponent()
  }
}

/// Foundation deliberately retains macOS /var aliases; SQLite NOFOLLOW checks every path
/// component. Resolve through POSIX only after rejecting application-controlled symlinks.
func canonicalRepositoryRoot(_ url: URL) throws -> URL {
  try requireSafeAncestors(url)
  var existing = url.standardizedFileURL
  var missing: [String] = []
  var info = stat()
  while lstat(existing.path, &info) != 0 && errno == ENOENT && existing.path != "/" {
    missing.insert(existing.lastPathComponent, at: 0)
    existing.deleteLastPathComponent()
  }
  guard let path = realpath(existing.path, nil) else {
    throw LocalPersistenceError.unsafeStore(url.lastPathComponent)
  }
  defer { free(path) }
  var result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
  for component in missing { result.appendPathComponent(component, isDirectory: true) }
  return result
}

private func fileFingerprint(_ url: URL) throws -> [Int64] {
  var value = stat()
  guard lstat(url.path, &value) == 0 else {
    throw LocalPersistenceError.unsafeStore(url.lastPathComponent)
  }
  return [
    Int64(value.st_dev), Int64(value.st_ino), value.st_size,
    Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
  ]
}
