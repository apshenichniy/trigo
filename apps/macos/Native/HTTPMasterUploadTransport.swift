import Foundation
import TrigoContracts

struct MasterUploadAuthorization: Sendable {
  let binding: ArchiveBinding
  let credentialAccount: String
  let token: String
}

/// One authenticated, same-archive transport. Audio requests and response metadata have fixed bounds.
public actor HTTPMasterUploadTransport: MasterUploadTransport {
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

  public func register(
    _ request: RegisterMasterUpload
  ) async throws -> StoredDocument<MasterUploadSession> {
    try await send(
      path: "v1/calls",
      method: "POST",
      body: Contract.encode(request),
      as: MasterUploadSession.self
    )
  }

  public func upload(
    callID: String,
    uploadID: String,
    part: UploadPartDescriptor,
    bytes: Data
  ) async throws -> StoredDocument<UploadPartReceipt> {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(uploadID)
    _ = try Contract.encode(part)
    guard bytes.count == part.byteLength, Contract.hash(bytes) == part.sha256 else {
      throw MasterUploadError.invalidPart
    }
    return try await send(
      path: "v1/calls/\(callID)/uploads/\(uploadID)/chunks/\(part.index)",
      method: "PUT",
      body: bytes,
      headers: [
        "content-type": "application/octet-stream", "x-trigo-byte-offset": String(part.byteOffset),
        "x-trigo-content-sha256": part.sha256,
      ],
      as: UploadPartReceipt.self
    )
  }

  public func finalize(
    callID: String,
    request: FinalizeMasterUpload
  ) async throws -> StoredDocument<VerifiedMasterReceipt> {
    try requireCanonicalIdentifier(callID)
    return try await send(
      path: "v1/calls/\(callID)/finalize",
      method: "POST",
      body: Contract.encode(request),
      as: VerifiedMasterReceipt.self
    )
  }

  private func send<Value: ContractDocument>(
    path: String,
    method: String,
    body: Data,
    headers: [String: String] = [:],
    as type: Value.Type
  ) async throws -> StoredDocument<Value> {
    guard body.count <= MediaMasterProfile.maximumRequestBytes else {
      throw MasterUploadError.transport(code: "upload_too_large", retry: .afterCorrection)
    }
    try Task.checkCancellation()
    let authority = try await connection.masterUploadAuthorization(archiveID: archiveID)
    let endpoint = authority.binding.serverURL.appending(path: path)
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("Bearer \(authority.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do { (bytes, response) = try await session.bytes(for: request) } catch {
      if Task.isCancelled { throw CancellationError() }
      throw MasterUploadError.transport(code: "upload_network_unavailable", retry: .retryable)
    }
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, http.url == endpoint,
      response.expectedContentLength <= 65_536
    else {
      await connection.reportMasterUploadIssue(.incompatible, authority: authority)
      throw MasterUploadError.remoteBlocked
    }
    var data = Data()
    do {
      for try await byte in bytes {
        guard data.count < 65_536 else { throw MasterUploadError.invalidReceipt }
        data.append(byte)
      }
    } catch let error as MasterUploadError {
      await connection.reportMasterUploadIssue(.incompatible, authority: authority)
      throw error
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw MasterUploadError.transport(code: "upload_response_lost", retry: .retryable)
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      await connection.reportMasterUploadIssue(.unauthorized, authority: authority)
      throw MasterUploadError.remoteBlocked
    }
    guard http.statusCode == 200 else {
      if let failure = try? Contract.decode(ErrorEnvelope.self, bytes: data).value.error,
        let retry = LifecycleRetryClassification(rawValue: failure.retry)
      {
        throw MasterUploadError.transport(code: failure.code, retry: retry)
      }
      if (500...599).contains(http.statusCode) {
        throw MasterUploadError.transport(code: "upload_server_unavailable", retry: .retryable)
      }
      await connection.reportMasterUploadIssue(.incompatible, authority: authority)
      throw MasterUploadError.remoteBlocked
    }
    do { return try Contract.decode(type, bytes: data) } catch {
      await connection.reportMasterUploadIssue(.incompatible, authority: authority)
      throw MasterUploadError.invalidReceipt
    }
  }
}
