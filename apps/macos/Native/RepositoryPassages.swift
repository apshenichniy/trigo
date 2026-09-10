import Foundation
import TrigoContracts

/// A rebuildable reader projection. Original turn identity and word positions still identify
/// the retained evidence; splitting a passage never publishes another canonical revision.
struct TranscriptPassage {
  let turnOrdinal: Int
  let firstWordOrdinal: Int
  let startMs: Int
  let endMs: Int
  let text: String
  let hasApproximateTiming: Bool
}

func transcriptPassages(_ revision: TranscriptRevision) -> [TranscriptPassage] {
  var tracks: [String: [TranscriptPassage]] = [:]
  for (ordinal, turn) in revision.turns.enumerated() {
    var boundaries = [0]
    // Some imported formats retain a separately formatted turn text. Without a lossless
    // word-to-text boundary, keep that original passage intact.
    if turn.text == turn.words.map(\.text).joined(separator: " ") {
      for index in turn.words.indices.dropFirst() {
        let previous = turn.words[index - 1]
        let next = turn.words[index]
        if previous.timingUncertain != true, next.timingUncertain != true,
          previous.startMs >= turn.startMs, previous.endMs >= previous.startMs,
          next.endMs <= turn.endMs, next.endMs >= next.startMs,
          next.startMs - previous.endMs > 1_200
        {
          boundaries.append(index)
        }
      }
    }
    if boundaries.count == 1 {
      tracks[turn.trackId, default: []]
        .append(
          .init(
            turnOrdinal: ordinal,
            firstWordOrdinal: 0,
            startMs: turn.startMs,
            endMs: turn.endMs,
            text: turn.text,
            hasApproximateTiming: turn.words.contains { $0.timingUncertain == true }
          )
        )
      continue
    }
    boundaries.append(turn.words.count)
    for index in 0..<(boundaries.count - 1) {
      let words = turn.words[boundaries[index]..<boundaries[index + 1]]
      func bounded(_ time: Int) -> Int { min(turn.endMs, max(turn.startMs, time)) }
      tracks[turn.trackId, default: []]
        .append(
          .init(
            turnOrdinal: ordinal,
            firstWordOrdinal: boundaries[index],
            startMs: words.map { bounded(min($0.startMs, $0.endMs)) }.min() ?? turn.startMs,
            endMs: words.map { bounded(max($0.startMs, $0.endMs)) }.max() ?? turn.endMs,
            text: words.map(\.text).joined(separator: " "),
            hasApproximateTiming: words.contains { $0.timingUncertain == true }
          )
        )
    }
  }
  // Merge channel heads rather than sorting all words/turns. Provider text order survives
  // approximate timestamps that run backward within one source.
  let keys = tracks.keys.sorted()
  var cursors: [String: Int] = [:]
  var result: [TranscriptPassage] = []
  while true {
    var selected: (String, TranscriptPassage)?
    for key in keys {
      guard let passages = tracks[key], cursors[key, default: 0] < passages.count else { continue }
      let head = passages[cursors[key, default: 0]]
      if selected == nil || head.startMs < selected!.1.startMs
        || (head.startMs == selected!.1.startMs && head.endMs < selected!.1.endMs)
      {
        selected = (key, head)
      }
    }
    guard let (key, passage) = selected else { break }
    result.append(passage)
    cursors[key, default: 0] += 1
  }
  return result
}

extension LocalRepository {
  func stagePassages(_ revision: TranscriptRevision, hash: String) async throws {
    try await stageRows(
      "INSERT OR IGNORE INTO revision_passages VALUES (?,?,?,?,?,?,?,?)",
      transcriptPassages(revision).enumerated()
        .map { ordinal, passage in
          [
            .text(hash), .int(ordinal), .int(passage.turnOrdinal), .int(passage.firstWordOrdinal),
            .int(passage.startMs), .int(passage.endMs), .text(passage.text),
            .int(passage.hasApproximateTiming ? 1 : 0),
          ]
        }
    )
    // Completion is durable only after every bounded preparation batch, including no speech.
    try await stageRows(
      "INSERT OR IGNORE INTO revision_passage_projections VALUES (?)",
      [[.text(hash)]]
    )
  }

  func ensurePassages(hash: String) async throws {
    let complete = try database.access {
      try
        !database.rows("SELECT hash FROM revision_passage_projections WHERE hash=?", [.text(hash)])
        .isEmpty
    }
    if !complete {
      let revision = try Contract.decode(TranscriptRevision.self, bytes: documentBytes(hash)).value
      try await stagePassages(revision, hash: hash)
    }
  }
}
