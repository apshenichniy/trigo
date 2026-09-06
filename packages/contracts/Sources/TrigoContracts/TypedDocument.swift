import Foundation

/// JSON-compatible exchange models. Always enter through Contract for strict validation.
public protocol ContractDocument: Codable, Equatable, Sendable {
  static var documentKind: String { get }
}

/// The typed projection and immutable byte identity have different lifetimes.
/// Editing a copy of `value` never changes these retained bytes or their checksum.
public struct StoredDocument<Value: ContractDocument>: Sendable {
  public let value: Value
  public let storedBytes: Data
  public var sha256: String { Contract.hash(storedBytes) }
}

extension StoredDocument where Value == CallDocument {
  public var callId: String { value.callId }
  public var documentVersion: Int? { value.documentVersion }
}

/// The deliberately bounded provider-options value: nested objects/arrays are not allowed.
public enum JSONScalar: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case boolean(Bool)
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      let value = try container.decode(Double.self)
      guard value.isFinite else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Expected a finite JSON number")
      }
      self = .number(value)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension Contract {
  public static func decode<Value: ContractDocument>(_ type: Value.Type, bytes: Data) throws
    -> StoredDocument<Value>
  {
    _ = try validate(Value.documentKind, bytes: bytes)
    return try typed(type, bytes: bytes)
  }

  public static func decodeStructure<Value: ContractDocument>(_ type: Value.Type, bytes: Data)
    throws
    -> StoredDocument<Value>
  {
    _ = try validateStructure(Value.documentKind, bytes: bytes)
    return try typed(type, bytes: bytes)
  }

  static func typed<Value: ContractDocument>(_ type: Value.Type, bytes: Data) throws
    -> StoredDocument<Value>
  {
    do {
      return StoredDocument(value: try JSONDecoder().decode(type, from: bytes), storedBytes: bytes)
    } catch { throw ContractError.structure }
  }

  /// Encode a new publication exactly once; never use this to reconstruct stored evidence.
  public static func encode<Value: ContractDocument>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    _ = try validate(Value.documentKind, bytes: bytes)
    return bytes
  }

  public static func decodeArchive(_ bytes: Data, references: [String: Data]) throws
    -> StoredDocument<CallDocument>
  {
    _ = try validateArchive(bytes, references: references)
    return try typed(CallDocument.self, bytes: bytes)
  }
}
