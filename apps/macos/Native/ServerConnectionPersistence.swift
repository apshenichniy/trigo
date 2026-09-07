import Darwin
import Foundation
import Security

enum ConnectionPersistenceError: Error {
  case invalidMetadata
  case unsafeMetadataFile
  case keychain(OSStatus)
  case invalidCredential
}

actor FileConnectionMetadataStore: ConnectionMetadataStoring {
  private let transportPolicy: ServerTransportPolicy
  private let url: URL
  private let fileManager: FileManager

  init(
    url: URL, fileManager: FileManager = .default,
    transportPolicy: ServerTransportPolicy = .httpsOnly
  ) {
    self.transportPolicy = transportPolicy
    self.url = url
    self.fileManager = fileManager
  }

  func load() throws -> ConnectionMetadata? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? 0) <= 65_536
    else { throw ConnectionPersistenceError.unsafeMetadataFile }
    let metadata = try JSONDecoder().decode(ConnectionMetadata.self, from: Data(contentsOf: url))
    try validate(metadata)
    return metadata
  }

  func save(_ metadata: ConnectionMetadata) throws {
    try validate(metadata)
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if fileManager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ConnectionPersistenceError.unsafeMetadataFile
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let temporary = directory.appending(
      path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try encoder.encode(metadata).write(to: temporary, options: .withoutOverwriting)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()
    let result: Int32 = temporary.withUnsafeFileSystemRepresentation { source in
      url.withUnsafeFileSystemRepresentation { destination in
        guard let source, let destination else { return Int32(-1) }
        return Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func validate(_ metadata: ConnectionMetadata) throws {
    guard metadata.formatVersion == 1 else { throw ConnectionPersistenceError.invalidMetadata }
    for connection in [metadata.committed, metadata.pending].compactMap({ $0 }) {
      guard
        transportPolicy.canonicalURL(connection.serverURL.absoluteString)
          == connection.serverURL,
        Self.isCanonicalUUID(connection.archiveId),
        Self.isCanonicalUUID(connection.credentialAccount)
      else { throw ConnectionPersistenceError.invalidMetadata }
    }
    let stored = [metadata.committed, metadata.pending].compactMap { $0 }
    if let committed = metadata.committed, let pending = metadata.pending {
      guard committed.archiveId == pending.archiveId, committed.stage == pending.stage else {
        throw ConnectionPersistenceError.invalidMetadata
      }
    }
    let accounts = stored.map(\.credentialAccount) + metadata.retiredCredentialAccounts
    guard Set(accounts).count == accounts.count,
      metadata.retiredCredentialAccounts.allSatisfy(Self.isCanonicalUUID)
    else { throw ConnectionPersistenceError.invalidMetadata }
  }

  private static func isCanonicalUUID(_ value: String) -> Bool {
    value.range(
      of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
      options: .regularExpression) != nil
  }
}

actor KeychainCredentialStore: CredentialStoring {
  private let service: String

  init(service: String) { self.service = service }

  func load(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let token = String(data: data, encoding: .utf8)
    else {
      if status == errSecSuccess { throw ConnectionPersistenceError.invalidCredential }
      throw ConnectionPersistenceError.keychain(status)
    }
    return token
  }

  func save(token: String, account: String) throws {
    guard let data = token.data(using: .utf8) else {
      throw ConnectionPersistenceError.invalidCredential
    }
    var attributes = baseQuery(account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw ConnectionPersistenceError.keychain(status) }
  }

  func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ConnectionPersistenceError.keychain(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
