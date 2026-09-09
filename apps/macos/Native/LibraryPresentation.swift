import Foundation

public struct LibraryDay: Identifiable, Equatable, Sendable {
  public let date: Date
  public let title: String
  public let calls: [LibraryCall]
  public var id: Date { date }

  public static func group(
    _ calls: [LibraryCall],
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> [LibraryDay] {
    let ordered = calls.sorted {
      $0.startedAt == $1.startedAt ? $0.callID > $1.callID : $0.startedAt > $1.startedAt
    }
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .full
    var days: [(Date, [LibraryCall])] = []
    for call in ordered {
      let day = calendar.startOfDay(for: call.startedDate)
      if days.last?.0 == day {
        days[days.count - 1].1.append(call)
      } else {
        days.append((day, [call]))
      }
    }
    return days.map { day, calls in
      .init(
        date: day,
        title: day == today
          ? "Today" : (day == yesterday ? "Yesterday" : formatter.string(from: day)),
        calls: calls
      )
    }
  }
}

public struct LibraryCallStatus: Equatable, Sendable {
  public let title: String
  public let symbol: String
  public let isPending: Bool
  public let needsAttention: Bool

  public init(_ call: LibraryCall) {
    let state = call.lifecycle
    if state.capture.state == .recording {
      self.init("Recording", "record.circle", pending: false)
    } else if state.replica.state == .conflict {
      self.init("Names need review", "person.crop.circle.badge.exclamationmark", attention: true)
    } else if state.upload.failure != nil || state.upload.state == .failed {
      self.init("Audio upload needs attention", "exclamationmark.icloud", attention: true)
    } else if state.transcription.failure != nil || state.transcription.state == .failed {
      self.init("Transcription needs attention", "exclamationmark.bubble", attention: true)
    } else if state.importState.failure != nil || state.importState.state == .failed {
      self.init("Transcript import needs attention", "exclamationmark.doc", attention: true)
    } else if state.replica.failure != nil {
      self.init("Sync needs attention", "exclamationmark.icloud", attention: true)
    } else if state.upload.state != .stored {
      self.init(
        state.upload.state == .uploading ? "Uploading audio" : "Waiting to upload",
        "icloud.and.arrow.up",
        pending: true
      )
    } else if call.activeRevisionID == nil {
      switch state.transcription.state {
      case .running: self.init("Transcribing", "text.bubble", pending: true)
      case .resultAvailable: self.init("Importing transcript", "text.badge.plus", pending: true)
      default: self.init("Waiting for transcription", "text.bubble", pending: true)
      }
    } else if state.transcription.state == .running || state.transcription.state == .queued {
      self.init("New transcript in progress", "text.bubble", pending: true)
    } else if state.importState.state != .imported {
      self.init("Importing transcript", "text.badge.plus", pending: true)
    } else if state.replica.state != .confirmed {
      self.init("Sync pending", "arrow.triangle.2.circlepath.icloud", pending: true)
    } else {
      self.init("Ready — saved on this Mac and server", "checkmark.icloud")
    }
  }

  private init(_ title: String, _ symbol: String, pending: Bool = false, attention: Bool = false) {
    self.title = title
    self.symbol = symbol
    isPending = pending
    needsAttention = attention
  }
}

public struct LibraryStage: Identifiable, Sendable {
  public let name: String
  public let value: String
  public let failure: LifecycleFailure?
  public var id: String { name }

  public static func stages(_ call: LibraryCall) -> [LibraryStage] {
    let s = call.lifecycle
    return [
      .init(name: "Recording", value: s.capture.state.rawValue, failure: s.capture.failure),
      .init(name: "Audio upload", value: s.upload.state.rawValue, failure: s.upload.failure),
      .init(
        name: "Transcription",
        value: s.transcription.state.rawValue,
        failure: s.transcription.failure
      ),
      .init(
        name: "Local import",
        value: s.importState.state.rawValue,
        failure: s.importState.failure
      ),
      .init(name: "Canonical sync", value: s.replica.state.rawValue, failure: s.replica.failure),
      .init(
        name: "Call availability",
        value: s.deletion.state.rawValue,
        failure: s.deletion.failure
      ),
    ]
  }
}

public enum LibraryFailure {
  public static func message(_ error: Error) -> String {
    switch error {
    case LocalPersistenceError.concurrentMutation, LocalPersistenceError.staleDocumentVersion:
      "This recording changed while the editor was open. Reopen the editor to review the latest names."
    case CanonicalSyncError.conflict:
      "Names changed on the server. Review both versions before choosing which names to keep."
    case CanonicalSyncError.invalidAnnotation, CanonicalSyncError.groupIdentityReused:
      "Choose at least two existing speaker labels and a nonblank group name. Reopen the editor if the membership changed."
    case CanonicalSyncError.deleted, LocalPersistenceError.callNotFound:
      "This recording is no longer available."
    default:
      "The local archive could not be read or updated. Your retained recordings have not been replaced. Try again."
    }
  }

  public static func synchronization(_ failure: LifecycleFailure) -> String {
    switch failure.code {
    case "unauthorized", "authentication_required", "connection_blocked":
      "Reconnect in Settings. Your local transcripts and names remain available."
    case "incompatible_document", "incompatible_contract", "compatibility":
      "This server uses an incompatible document format. Update the matching Trigo app and server. Local names remain saved."
    default:
      "Server work is waiting for a connection or correction. Local transcripts and names remain available."
    }
  }
}
