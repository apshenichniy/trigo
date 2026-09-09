import Foundation
import TrigoContracts

/// Paths are constructed locally from validated identities. No retained artifact URL or
/// redirect can move an owner credential outside the bound archive origin.
public actor HTTPCanonicalSyncTransport: CanonicalSyncTransport {
  private let connection: ServerConnection
  private let archiveID: String
  private let session: URLSession

  public init(connection: ServerConnection, archiveID: String, timeout: TimeInterval = 120) {
    self.connection = connection
    self.archiveID = archiveID
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 1
    session = URLSession(
      configuration: configuration,
      delegate: RedirectRejectingDelegate(),
      delegateQueue: nil
    )
  }

  public func catalog(cursor: String?) async throws -> CallCatalogPage {
    try await decoded(
      CallCatalogPage.self,
      path: "v1/calls",
      query: cursor.map { [.init(name: "cursor", value: $0)] } ?? []
    )
  }

  public func changes(cursor: String) async throws -> CallChangesPage {
    try await decoded(
      CallChangesPage.self,
      path: "v1/changes",
      query: [.init(name: "cursor", value: cursor)]
    )
  }

  public func document(callID: String, version: Int?) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    if let version, version <= 0 { throw CanonicalSyncError.invalidResult }
    return try await send(
      path: "v1/calls/\(callID)/document",
      query: version.map { [.init(name: "documentVersion", value: String($0))] } ?? [],
      maximum: 16_000_000,
      retained: true
    )
  }

  public func audioManifest(callID: String) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    return try await send(
      path: "v1/calls/\(callID)/audio-manifest",
      maximum: 16_000_000,
      retained: true
    )
  }

  public func results(callID: String, cursor: String?) async throws -> TranscriptResultsPage {
    try requireCanonicalIdentifier(callID)
    return try await decoded(
      TranscriptResultsPage.self,
      path: "v1/calls/\(callID)/results",
      query: cursor.map { [.init(name: "cursor", value: $0)] } ?? []
    )
  }

  public func revision(callID: String, revisionID: String) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    return try await send(
      path: "v1/calls/\(callID)/revisions/\(revisionID)",
      maximum: 16_000_000,
      retained: true
    )
  }

  public func provenance(callID: String, revisionID: String) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    return try await send(
      path: "v1/calls/\(callID)/revisions/\(revisionID)/provenance",
      maximum: 65_536,
      retained: true
    )
  }

  public func publish(
    callID: String,
    request: PublishCallReplica
  ) async throws -> StoredDocument<ReplicaReceipt> {
    try requireCanonicalIdentifier(callID)
    return try Contract.decode(
      ReplicaReceipt.self,
      bytes: await send(
        path: "v1/calls/\(callID)/document",
        method: "PUT",
        body: Contract.encode(request)
      )
    )
  }

  public func requestTranscription(
    callID: String,
    request: RequestTranscription
  ) async throws -> TranscriptionOperation {
    try requireCanonicalIdentifier(callID)
    return try await decoded(
      TranscriptionOperation.self,
      path: "v1/calls/\(callID)/transcriptions",
      method: "POST",
      body: Contract.encode(request)
    )
  }

  public func operation(operationID: String) async throws -> TranscriptionOperation {
    try requireCanonicalIdentifier(operationID)
    return try await decoded(TranscriptionOperation.self, path: "v1/operations/\(operationID)")
  }

  private func decoded<T: ContractDocument>(
    _ type: T.Type,
    path: String,
    query: [URLQueryItem] = [],
    method: String = "GET",
    body: Data? = nil
  ) async throws -> T {
    let bytes = try await send(path: path, query: query, method: method, body: body)
    do { return try Contract.decode(type, bytes: bytes).value } catch {
      throw CanonicalSyncError.incompatibleDocument
    }
  }

  private func send(
    path: String,
    query: [URLQueryItem] = [],
    method: String = "GET",
    body: Data? = nil,
    maximum: Int = 262_144,
    retained: Bool = false
  ) async throws -> Data {
    try Task.checkCancellation()
    guard (body?.count ?? 0) <= 48_000_000 else { throw CanonicalSyncError.incompatibleDocument }
    let authority: ServerOperationAuthorization
    do { authority = try await connection.serverOperationAuthorization(archiveID: archiveID) } catch {
      throw CanonicalSyncError.unauthorized
    }
    var components = URLComponents(
      url: authority.binding.serverURL.appending(path: path),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = query.isEmpty ? nil : query
    guard let endpoint = components?.url else { throw CanonicalSyncError.incompatibleDocument }
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("Bearer \(authority.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await session.bytes(for: request) } catch {
      if Task.isCancelled { throw CancellationError() }
      throw CanonicalSyncError.serverUnavailable
    }
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, http.url == endpoint,
      response.expectedContentLength <= maximum
    else { throw CanonicalSyncError.incompatibleDocument }
    if http.statusCode == 401 || http.statusCode == 403 {
      await connection.reportServerOperationIssue(.unauthorized, authority: authority)
      throw CanonicalSyncError.unauthorized
    }
    let bound = http.statusCode == 200 ? maximum : 65_536
    var data = Data()
    do {
      for try await byte in bytes {
        guard data.count < bound else { throw CanonicalSyncError.incompatibleDocument }
        data.append(byte)
      }
    } catch let error as CanonicalSyncError { throw error } catch {
      if Task.isCancelled { throw CancellationError() }
      throw CanonicalSyncError.serverUnavailable
    }
    guard http.statusCode == 200 else {
      if let failure = try? Contract.decode(ErrorEnvelope.self, bytes: data).value.error {
        switch failure.code {
        case "sync_conflict": throw CanonicalSyncError.conflict
        case "sync_cursor_reset": throw CanonicalSyncError.cursorReset
        case "sync_not_found": throw CanonicalSyncError.missingCanonicalDocument
        case "call_deleted": throw CanonicalSyncError.deleted
        case "sync_owner_changed", "asr_owner_changed": throw CanonicalSyncError.unauthorized
        default:
          throw CanonicalSyncError.remote(
            code: failure.code,
            retry: LifecycleRetryClassification(rawValue: failure.retry) ?? .afterCorrection
          )
        }
      }
      if (500...599).contains(http.statusCode) { throw CanonicalSyncError.serverUnavailable }
      throw CanonicalSyncError.incompatibleDocument
    }
    guard
      http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    else { throw CanonicalSyncError.incompatibleDocument }
    if retained, http.value(forHTTPHeaderField: "x-trigo-content-sha256") != Contract.hash(data) {
      throw CanonicalSyncError.invalidResult
    }
    return data
  }
}
