import Foundation
import TrigoContracts

/// The owner credential is used only to obtain a temporary playback capability.
/// Media requests carry that capability in a header and never use credential-bearing URLs.
public actor HTTPPlaybackTransport: CallPlaybackTransport {
  private let connection: ServerConnection
  private let archiveID: String
  private let session: URLSession

  public init(connection: ServerConnection, archiveID: String, timeout: TimeInterval = 30) {
    self.connection = connection
    self.archiveID = archiveID
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(
      configuration: configuration,
      delegate: RedirectRejectingDelegate(),
      delegateQueue: nil
    )
  }

  public func grant(callID: String, operationID: String) async throws -> PlaybackAccess {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(operationID)
    let authority: ServerOperationAuthorization
    do { authority = try await connection.serverOperationAuthorization(archiveID: archiveID) } catch
    { throw CallPlaybackError.accessBlocked }
    let endpoint = authority.binding.serverURL.appending(path: "v1/calls/\(callID)/playback")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = try Contract.encode(
      RequestPlayback(schemaVersion: 1, operationId: operationID)
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(authority.token)", forHTTPHeaderField: "Authorization")
    do {
      let (bytes, _) = try await send(request, maximumBytes: 65_536)
      let grant = try Contract.decode(PlaybackGrant.self, bytes: bytes).value
      let access = PlaybackAccess(grant: grant, binding: authority.binding)
      try PlaybackValidation.access(access, callID: callID)
      guard grant.operationId == operationID else { throw CallPlaybackError.invalidGrant }
      let current = await connection.snapshot()
      guard current.serverOperationsAvailable, current.binding == authority.binding else {
        throw CallPlaybackError.accessBlocked
      }
      return access
    } catch let issue as CallPlaybackError {
      if issue == .accessBlocked {
        await connection.reportServerOperationIssue(.unauthorized, authority: authority)
      }
      throw issue
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await connection.reportServerOperationIssue(.incompatible, authority: authority)
      throw CallPlaybackError.invalidGrant
    }
  }

  public func segment(access: PlaybackAccess, index: Int) async throws -> PlaybackPCM {
    try PlaybackValidation.access(access, callID: access.grant.callId)
    let current = await connection.snapshot()
    guard access.binding.archiveId == archiveID, current.binding == access.binding,
      current.serverOperationsAvailable
    else { throw CallPlaybackError.accessBlocked }
    let grant = access.grant
    guard index >= 0, index < grant.media.segmentCount else { throw CallPlaybackError.invalidMedia }
    let endpoint = access.binding.serverURL.appending(
      path: "v1/calls/\(grant.callId)/playback/\(grant.grantId)/segments/\(index)"
    )
    var request = URLRequest(url: endpoint)
    request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
    request.setValue("audio/wav", forHTTPHeaderField: "Accept")
    let startFrame = index * grant.media.segmentFrames
    let frameCount = min(grant.media.segmentFrames, grant.media.frameCount - startFrame)
    let (bytes, response) = try await send(request, maximumBytes: 44 + frameCount * 4)
    guard response.value(forHTTPHeaderField: "Content-Type") == "audio/wav",
      response.value(forHTTPHeaderField: "X-Trigo-Start-Frame") == String(startFrame),
      response.value(forHTTPHeaderField: "X-Trigo-Frame-Count") == String(frameCount),
      response.value(forHTTPHeaderField: "X-Trigo-Content-SHA256") == Contract.hash(bytes),
      response.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true
    else { throw CallPlaybackError.invalidMedia }
    try Task.checkCancellation()
    let latest = await connection.snapshot()
    guard latest.serverOperationsAvailable, latest.binding == access.binding else {
      throw CallPlaybackError.accessBlocked
    }
    return try PlaybackValidation.decodeWave(bytes, startFrame: startFrame, frameCount: frameCount)
  }

  private func send(_ input: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
  {
    try Task.checkCancellation()
    var request = input
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let stream: URLSession.AsyncBytes
    let response: URLResponse
    do { (stream, response) = try await session.bytes(for: request) } catch {
      if Task.isCancelled { throw CancellationError() }
      throw CallPlaybackError.transport(code: "playback_network_unavailable", retry: .retryable)
    }
    defer { stream.task.cancel() }
    guard let http = response as? HTTPURLResponse, http.url == request.url else {
      throw CallPlaybackError.invalidMedia
    }
    let limit = http.statusCode == 200 ? maximumBytes : 65_536
    guard response.expectedContentLength <= limit else { throw CallPlaybackError.invalidMedia }
    var data = Data()
    data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
    do {
      for try await byte in stream {
        guard data.count < limit else { throw CallPlaybackError.invalidMedia }
        data.append(byte)
      }
    } catch let issue as CallPlaybackError { throw issue } catch {
      if Task.isCancelled { throw CancellationError() }
      throw CallPlaybackError.transport(code: "playback_response_lost", retry: .retryable)
    }
    guard http.statusCode == 200 else {
      let error = try? Contract.decode(ErrorEnvelope.self, bytes: data).value.error
      switch error?.code {
      case "playback_grant_expired": throw CallPlaybackError.grantExpired
      case "playback_grant_invalid": throw CallPlaybackError.invalidGrant
      case "playback_not_stored": throw CallPlaybackError.notStored
      case "playback_not_found": throw CallPlaybackError.notFound
      case "playback_catalog_invalid": throw CallPlaybackError.invalidMedia
      case "playback_deleted": throw CallPlaybackError.deleted
      case "playback_no_audio": throw CallPlaybackError.noAudio
      default: break
      }
      if http.statusCode == 401 || http.statusCode == 403 { throw CallPlaybackError.accessBlocked }
      if let error, let retry = LifecycleRetryClassification(rawValue: error.retry) {
        throw CallPlaybackError.transport(code: error.code, retry: retry)
      }
      throw CallPlaybackError.transport(code: "playback_server_unavailable", retry: .retryable)
    }
    return (data, http)
  }
}
