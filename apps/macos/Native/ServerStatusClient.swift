import Foundation
import TrigoContracts

enum ServerStatusDecoder {
  static func decode(_ data: Data) throws -> ServerStatus {
    do {
      let value = try Contract.decode(StatusResponse.self, bytes: data).value
      guard let stage = ServerStage(rawValue: value.stage),
        let transcription = TranscriptionReadiness(rawValue: value.readiness.transcription),
        let operations = CallOperationsReadiness(rawValue: value.readiness.callOperations)
      else { throw ConnectionIssue.incompatible }
      return ServerStatus(
        schemaVersion: value.schemaVersion,
        apiVersion: value.apiVersion,
        archiveId: value.archiveId,
        stage: stage,
        readiness: .init(
          archive: value.readiness.archive,
          ownerAuthentication: value.readiness.ownerAuthentication,
          transcription: transcription,
          callOperations: operations
        ),
        errors: value.errors.map { .init(code: $0.code, retry: $0.retry, message: $0.message) }
      )
    } catch {
      throw ConnectionIssue.incompatible
    }
  }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

actor HTTPSStatusClient: ServerStatusFetching {
  private let transportPolicy: ServerTransportPolicy
  private let session: URLSession

  init(timeout: TimeInterval = 15, transportPolicy: ServerTransportPolicy = .httpsOnly) {
    self.transportPolicy = transportPolicy
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    session = URLSession(
      configuration: configuration,
      delegate: RedirectRejectingDelegate(),
      delegateQueue: nil
    )
  }

  func fetch(serverURL: URL, token: String) async throws -> ServerStatus {
    guard transportPolicy.canonicalURL(serverURL.absoluteString) == serverURL else {
      throw ConnectionIssue.invalidServerURL
    }
    let endpoint = serverURL.appending(path: "v1/status")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw ConnectionIssue.unreachable
    }
    guard let http = response as? HTTPURLResponse, http.url == endpoint else {
      throw ConnectionIssue.incompatible
    }
    switch http.statusCode {
    case 200:
      return try ServerStatusDecoder.decode(data)
    case 401, 403:
      throw ConnectionIssue.unauthorized
    case 404, 405:
      throw ConnectionIssue.incompatible
    default:
      throw ConnectionIssue.unreachable
    }
  }
}
