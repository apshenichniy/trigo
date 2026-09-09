import Combine
import Foundation

/// The application owns upload/sync. The reader owns selection and cancellable playback only.
@MainActor public struct LibrarySession {
  public let repository: LocalRepository
  public let player: CallAudioPlayer
  public let retry: (String) async -> Void

  public init(
    repository: LocalRepository,
    player: CallAudioPlayer,
    retry: @escaping (String) async -> Void
  ) {
    self.repository = repository
    self.player = player
    self.retry = retry
  }
}

@MainActor public final class LibraryModel: ObservableObject {
  @Published public private(set) var calls: [LibraryCall] = []
  @Published public private(set) var days: [LibraryDay] = []
  @Published public private(set) var selectedCallID: String?
  @Published public private(set) var selectedRevisionID: String?
  @Published public private(set) var revisions: [LibraryRevision] = []
  @Published public private(set) var turns: [LocalTurn] = []
  @Published public private(set) var speakers: [LocalSpeaker] = []
  @Published public private(set) var conflicts: [SpeakerAnnotationConflict] = []
  @Published public private(set) var synchronization: ArchiveSynchronizationStatus?
  @Published public private(set) var playback = CallPlaybackState()
  @Published public private(set) var isLoading = true
  @Published public private(set) var isReading = false
  @Published public private(set) var needsConnection = false
  @Published public private(set) var failure: String?
  @Published public var sidebarVisible = true
  @Published public var showsDetails = false
  private let makeSession: () async throws -> LibrarySession?
  private let preferences: UserDefaults
  private let clock: () -> Date
  private let calendar: () -> Calendar
  private var session: LibrarySession?
  private var ticker: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?
  private var playerObservation: AnyCancellable?
  private var generation = 0
  private var observedVersion: [Int]?
  private var refreshing = false
  private var readVersion: Int?
  private var readStateVersion: Int?
  private static let selectionKey = "library.selectedCallID"

  public init(
    preferences: UserDefaults,
    clock: @escaping () -> Date = { Date() },
    calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
    makeSession: @escaping () async throws -> LibrarySession?
  ) {
    self.preferences = preferences
    self.clock = clock
    self.calendar = calendar
    self.makeSession = makeSession
    selectedCallID = preferences.string(forKey: Self.selectionKey)
  }

  deinit { ticker?.cancel(); selectionTask?.cancel() }

  public var selectedCall: LibraryCall? { calls.first { $0.callID == selectedCallID } }
  public var selectedRevision: LibraryRevision? {
    revisions.first { $0.revisionID == selectedRevisionID }
  }
  public var hasMoreTurns: Bool { turns.count < (selectedRevision?.turnCount ?? 0) }
  public var canPlay: Bool {
    hasStoredAudio && (playback.callID != selectedCallID || playback.failure == nil)
  }
  private var hasStoredAudio: Bool {
    selectedCall?.lifecycle.upload.state == .stored && (selectedCall?.durationMs ?? 0) > 0
  }
  public var canRetryPlayback: Bool {
    guard hasStoredAudio, playback.callID == selectedCallID, let failure = playback.failure else {
      return false
    }
    switch failure {
    case .transport(_, let retry): return retry != .never
    case .accessBlocked, .grantExpired, .invalidGrant, .audioOutput: return true
    default: return false
    }
  }
  public var playbackReason: String? {
    if let failure = playback.failure { return failure.message }
    if !canPlay {
      return "Playback becomes available after the complete audio is stored on the server."
    }
    return nil
  }

  public func start(selecting callID: String? = nil) {
    if let callID { selectCall(callID) }
    guard ticker == nil else { return }
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  public func close() {
    generation += 1
    selectionTask?.cancel(); selectionTask = nil
    isReading = false
    ticker?.cancel(); ticker = nil
    session?.player.pause()
  }

  public func refresh(
    force: Bool = false,
    now: Date? = nil,
    calendar: Calendar? = nil
  ) async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false; isLoading = false }
    do {
      if session == nil {
        session = try await makeSession()
        if let player = session?.player {
          playerObservation = player.$state.sink { [weak self] in self?.playback = $0 }
        }
      }
      guard let session else { needsConnection = true; return }
      needsConnection = false
      let version = try session.repository.presentationVersion()
      if force || version != observedVersion {
        var updated: [LibraryCall] = []
        while true {
          let page = try await session.repository.libraryCalls(after: updated.last?.callID ?? "")
          updated.append(contentsOf: page)
          if page.count < 100 { break }
          try Task.checkCancellation()
        }
        updated.sort {
          $0.startedDate == $1.startedDate ? $0.callID > $1.callID : $0.startedDate > $1.startedDate
        }
        let oldIndex = calls.firstIndex { $0.callID == selectedCallID } ?? 0
        calls = updated
        synchronization = try session.repository.synchronizationStatus()
        observedVersion = version
        failure = nil
        if !updated.contains(where: { $0.callID == selectedCallID }) {
          let next = updated.isEmpty ? nil : updated[min(oldIndex, updated.count - 1)].callID
          changeSelection(next, load: false)
        }
      }
      if selectedCall?.documentVersion != readVersion
        || selectedCall?.lifecycle.stateVersion != readStateVersion || force
      {
        await readSelection(preservingCount: true)
      }
      let grouped = LibraryDay.group(
        calls,
        now: now ?? clock(),
        calendar: calendar ?? self.calendar()
      )
      if grouped != days { days = grouped }
    } catch is CancellationError {} catch {
      failure = LibraryFailure.message(error)
    }
  }

  public func selectCall(_ callID: String?) {
    changeSelection(callID, load: true)
  }

  private func changeSelection(_ callID: String?, load: Bool) {
    guard callID != selectedCallID || readVersion == nil else { return }
    generation += 1
    selectionTask?.cancel()
    session?.player.clear()
    selectedCallID = callID
    preferences.set(callID, forKey: Self.selectionKey)
    selectedRevisionID = nil
    revisions = []; turns = []; speakers = []; conflicts = []; readVersion = nil;
    readStateVersion = nil
    if load { selectionTask = Task { @MainActor [weak self] in await self?.readSelection() } }
  }

  public func selectRevision(_ revisionID: String) {
    guard revisions.contains(where: { $0.revisionID == revisionID }),
      revisionID != selectedRevisionID
    else { return }
    generation += 1
    selectionTask?.cancel()
    session?.player.pause()
    selectedRevisionID = revisionID
    turns = []; speakers = []
    // Cleared passages are not a completed read, even if the call's document is unchanged.
    readVersion = nil; readStateVersion = nil
    selectionTask = Task { @MainActor [weak self] in await self?.readSelection() }
  }

  public func loadMoreTurns() async {
    await readSelection(turnLimit: turns.count + 100, preservingCount: true)
  }

  private func readSelection(turnLimit: Int = 100, preservingCount: Bool = false) async {
    guard let session, let callID = selectedCallID else { return }
    let epoch = generation
    isReading = true
    defer { if epoch == generation { isReading = false } }
    do {
      guard let call = try await session.repository.libraryCall(callID: callID) else { return }
      let retained = try await session.repository.libraryRevisions(callID: callID)
      let revisionID =
        retained.contains(where: { $0.revisionID == selectedRevisionID })
        ? selectedRevisionID : call.activeRevisionID ?? retained.first?.revisionID
      var loadedTurns: [LocalTurn] = []
      var loadedSpeakers: [LocalSpeaker] = []
      if let revisionID {
        let limit = preservingCount ? max(turnLimit, turns.count) : turnLimit
        while loadedTurns.count < limit {
          let page = try await session.repository.turns(
            callID: callID,
            revisionID: revisionID,
            after: loadedTurns.last?.ordinal ?? -1
          )
          loadedTurns.append(contentsOf: page)
          if page.count < 100 { break }
          try Task.checkCancellation()
        }
        while true {
          let page = try await session.repository.speakers(
            callID: callID,
            revisionID: revisionID,
            after: loadedSpeakers.last?.ordinal ?? -1
          )
          loadedSpeakers.append(contentsOf: page)
          if page.count < 100 { break }
          try Task.checkCancellation()
        }
      }
      let comparisons = try await session.repository.annotationConflicts(callID: callID)
      guard epoch == generation, !Task.isCancelled,
        try await session.repository.libraryCall(callID: callID)?.documentVersion
          == call.documentVersion
      else { return }
      revisions = retained; selectedRevisionID = revisionID
      turns = loadedTurns; speakers = loadedSpeakers; conflicts = comparisons
      readVersion = call.documentVersion
      readStateVersion = call.lifecycle.stateVersion
      failure = nil
    } catch is CancellationError {} catch {
      if epoch == generation { failure = LibraryFailure.message(error) }
    }
  }

  public func save(_ edit: SpeakerAnnotationEdit) async throws {
    guard let session else { throw CanonicalSyncError.missingCanonicalDocument }
    _ = try await session.repository.editSpeakerAnnotations(edit)
    await session.retry(edit.callID)
    await refresh(force: true)
  }

  public func resolve(
    _ conflict: SpeakerAnnotationConflict,
    choice: SpeakerConflictChoice,
    operationID: String
  ) async throws {
    guard let session else { throw CanonicalSyncError.missingCanonicalDocument }
    _ = try await session.repository.resolveSpeakerAnnotationConflict(
      callID: conflict.callID,
      revisionID: conflict.revisionID,
      serverDocumentVersion: conflict.serverDocumentVersion,
      choice: choice,
      operationID: operationID
    )
    await session.retry(conflict.callID)
    await refresh(force: true)
  }

  public func retrySynchronization() async {
    guard let session, let call = selectedCall else { return }
    await session.retry(call.callID)
    await refresh(force: true)
  }

  public func togglePlayback() async {
    guard let session, let callID = selectedCallID, canPlay else { return }
    if playback.phase == .playing { session.player.pause(); return }
    if playback.callID == callID {
      await session.player.play()
    } else {
      await session.player.load(callID: callID, autoplay: true)
    }
  }

  public func seek(to positionMs: Int, play: Bool) async {
    guard let session, let callID = selectedCallID, canPlay else { return }
    let epoch = generation
    if playback.callID != callID {
      await session.player.load(callID: callID, positionMs: positionMs, autoplay: play)
    } else {
      await session.player.seek(positionMs: positionMs)
      if play, epoch == generation, selectedCallID == callID, canPlay {
        await session.player.play()
      }
    }
  }

  public func retryPlayback() async {
    guard canRetryPlayback, let session, let callID = selectedCallID else { return }
    // An explicit retry reacquires server access at the retained position without autoplay.
    await session.player.load(callID: callID, positionMs: playback.positionMs, autoplay: false)
  }
}
