import CryptoKit
import Foundation
import TrigoContracts

let repositoryDocumentChunkBytes = 256 * 1024

extension LocalRepository {
  @discardableResult
  func stageDocument(_ bytes: Data) async throws -> String {
    let hash = Contract.hash(bytes)
    var offset = 0
    try await stageDocumentChunks(hash: hash, byteCount: bytes.count) {
      guard offset < bytes.count else { return nil }
      let end = min(bytes.count, offset + repositoryDocumentChunkBytes)
      defer { offset = end }
      return bytes.subdata(in: offset..<end)
    }
    return hash
  }

  func documentBytes(_ hash: String) throws -> Data {
    var result = Data()
    try forEachDocumentChunk(
      hash: hash,
      prepare: { result.reserveCapacity($0) },
      consume: { result.append($0) }
    )
    return result
  }

  /// Both in-memory and file sources use the same bounded immutable preparation. Retained
  /// partial chunks must match before completion; corrupt completed documents cannot be repaired
  /// by replay. Source reads and hashing run outside SQL ownership, with a yield between chunks.
  func stageDocumentChunks(hash: String, byteCount: Int, next: () throws -> Data?) async throws {
    guard byteCount >= 0 else { throw invalidRow() }
    let complete = try database.access {
      try database.transaction {
        try database.execute(
          "INSERT OR IGNORE INTO documents VALUES (?,?,0)",
          [.text(hash), .int(byteCount)]
        )
        guard
          let row =
            try database.rows(
              "SELECT byte_count,complete FROM documents WHERE hash=?",
              [.text(hash)]
            )
            .first,
          try row.int(0) == byteCount
        else { throw LocalPersistenceError.immutableConflict(hash) }
        return try row.int(1) == 1
      }
    }
    if complete { try forEachDocumentChunk(hash: hash) { _ in } }
    var count = 0
    var part = 0
    var digest = SHA256()
    while let bytes = try next(), !bytes.isEmpty {
      guard bytes.count <= repositoryDocumentChunkBytes, bytes.count <= byteCount - count else {
        throw ContractError.checksum
      }
      try database.access {
        try database.transaction {
          if !complete {
            try database.execute(
              "INSERT OR IGNORE INTO document_chunks VALUES (?,?,?)",
              [.text(hash), .int(part), .blob(bytes)]
            )
          }
          guard
            let row =
              try database.rows(
                "SELECT bytes FROM document_chunks WHERE hash=? AND part=?",
                [.text(hash), .int(part)]
              )
              .first,
            try row.data(0) == bytes
          else { throw LocalPersistenceError.immutableConflict(hash) }
        }
      }
      count += bytes.count
      part += 1
      digest.update(data: bytes)
      await Task.yield()
    }
    guard count == byteCount, Data(digest.finalize()).masterHex == hash else {
      throw ContractError.checksum
    }
    if !complete {
      try database.access {
        try database.transaction {
          try database.execute("UPDATE documents SET complete=1 WHERE hash=?", [.text(hash)])
        }
      }
    }
  }

  /// Readers share completeness, chunk bounds, length and checksum validation. Only Data callers
  /// allocate the full result; streaming consumers retain one chunk and run outside SQL ownership.
  func forEachDocumentChunk(
    hash: String,
    prepare: (Int) -> Void = { _ in },
    consume: (Data) throws -> Void
  ) throws {
    let size = try database.access {
      guard
        let row =
          try database.rows(
            "SELECT byte_count,complete FROM documents WHERE hash=?",
            [.text(hash)]
          )
          .first,
        try row.int(1) == 1, try row.int(0) >= 0
      else { throw invalidRow() }
      return try row.int(0)
    }
    prepare(size)
    var count = 0
    var part = 0
    var digest = SHA256()
    while count < size {
      let bytes = try database.access {
        guard
          let row =
            try database.rows(
              "SELECT bytes FROM document_chunks WHERE hash=? AND part=?",
              [.text(hash), .int(part)]
            )
            .first
        else { throw invalidRow() }
        return try row.data(0)
      }
      guard !bytes.isEmpty, bytes.count <= repositoryDocumentChunkBytes,
        bytes.count <= size - count
      else { throw invalidRow() }
      try consume(bytes)
      digest.update(data: bytes)
      count += bytes.count
      part += 1
    }
    guard Data(digest.finalize()).masterHex == hash else { throw ContractError.checksum }
  }
}
