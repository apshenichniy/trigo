import Foundation

@testable import TrigoNative

func jsonObject(_ bytes: Data) throws -> [String: Any] {
  guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
    throw LocalPersistenceError.invalidStoredDocument("Expected a JSON object")
  }
  return value
}
