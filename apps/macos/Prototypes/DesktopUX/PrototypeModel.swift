// THROWAWAY DESIGN PROTOTYPE. Synthetic data only; never import production services.
import AppKit
import Combine
import SwiftUI

enum ReadingState: String, CaseIterable, Identifiable {
    case ready = "Ready"
    case processing = "Processing"
    case offline = "Waiting for connection"
    case noSpeech = "No speech"
    case failed = "Transcription failed"
    case interrupted = "Recording interrupted"
    var id: String { rawValue }
}

enum CaptureState: String {
    case idle = "Idle"
    case starting = "Starting recording"
    case recording = "Recording"
    case saving = "Saving recording"
    case saved = "Recording saved"
    case interrupted = "Recording interrupted"
    case saveFailed = "Recording stopped — save not confirmed"
    case stopUnconfirmed = "Cannot confirm recording has stopped"
    case startFailed = "Couldn't start recording"
}

struct SampleCall: Identifiable {
    let id: UUID
    var source: String
    let bundle: String
    let group: String
    let time: String
    let date: String
    let minutes: Int
    var state: ReadingState
    init(_ source: String, _ bundle: String, _ group: String, _ time: String, _ date: String, _ minutes: Int, state: ReadingState = .ready) {
        id = UUID(); self.source = source; self.bundle = bundle; self.group = group
        self.time = time; self.date = date; self.minutes = minutes; self.state = state
    }
}

struct SampleTurn: Identifiable {
    let id: Int
    let time: Int
    let speaker: String
    let text: String
}

let sampleTurns: [SampleTurn] = [
    .init(id: 0, time: 0, speaker: "Speaker 1", text: "Давай сначала проверим, что запись сохраняется локально.\nОтправка на сервер может продолжаться после завершения звонка."),
    .init(id: 1, time: 13, speaker: "Speaker 2", text: "Пользователь должен сразу увидеть звонок в библиотеке,\nдаже если транскрипт ещё обрабатывается."),
    .init(id: 2, time: 29, speaker: "Speaker 1", text: "Если сеть пропала, исходное аудио остаётся на компьютере.\nКогда соединение вернётся, приложение повторит отправку."),
    .init(id: 3, time: 46, speaker: "Speaker 2", text: "Тогда отдельно показываем, что звонок сохранён,\nа текст пока не готов."),
    .init(id: 4, time: 62, speaker: "Speaker 1", text: "Источник записи не меняется, когда пользователь\nпереключается между окнами."),
    .init(id: 5, time: 73, speaker: "Speaker 2", text: "Для проверки возьмём два независимых звуковых сигнала\nи сравним их после сохранения."),
    .init(id: 6, time: 89, speaker: "Speaker 1", text: "Хорошо. Ещё нужно проверить узкое окно и длинные названия приложений. Текст должен оставаться удобным для чтения."),
    .init(id: 7, time: 111, speaker: "Speaker 2", text: "И отдельно посмотрим, как выглядит отсутствие речи. Не стоит подменять пустой результат придуманным текстом."),
]

func clockText(_ seconds: Int) -> String {
    String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
}

@MainActor final class PrototypeModel: ObservableObject {
    @Published var calls: [SampleCall]
    @Published var selectedID: UUID
    @Published var capture: CaptureState = .idle { didSet { onCaptureChange?() } }
    @Published var panelVisible = false { didSet { onPanelVisibilityChange?() } }
    @Published var elapsed = 252
    @Published var microphoneMuted = false { didSet { onCaptureChange?() } }
    @Published var microphoneAvailable = true { didSet { onCaptureChange?() } }
    @Published var microphonePending = false { didSet { onCaptureChange?() } }
    @Published var microphoneSignal = true
    @Published var applicationSignal = true
    @Published var position = 29.0
    @Published var playing = false
    @Published var volume = true
    @Published var appearance = "Light" { didSet { onAppearanceChange?() } }
    @Published var reduceMotion = false
    @Published var longTitle = false
    @Published var launchAtLogin = false
    @Published var tick = 0.0
    @Published var simulateSaveFailure = false
    @Published var notice: String?
    var onCaptureChange: (() -> Void)?
    var onPanelVisibilityChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var openLibrary: (() -> Void)?
    var openSettings: (() -> Void)?
    var openControls: (() -> Void)?
    var resizeLibrary: ((Bool) -> Void)?
    private var timer: Timer?
    private var transition = 0

    init() {
        let yesterday = "Yesterday / Sep 7", sunday = "Sunday / Sep 6", friday = "Friday / Sep 4"
        let chrome = "com.google.Chrome", telegram = "ru.keepcoder.Telegram"
        let fixtures: [SampleCall] = [
            .init("Google Chrome", chrome, yesterday, "17:40", "Mon, Sep 7, 2026", 38),
            .init("Telegram", telegram, yesterday, "14:15", "Mon, Sep 7, 2026", 12),
            .init("Google Chrome", chrome, yesterday, "10:30", "Mon, Sep 7, 2026", 46),
            .init("Telegram", telegram, sunday, "18:00", "Sun, Sep 6, 2026", 24),
            .init("Google Chrome", chrome, sunday, "09:45", "Sun, Sep 6, 2026", 31),
            .init("Google Chrome", chrome, friday, "16:20", "Fri, Sep 4, 2026", 55),
            .init("Telegram", telegram, friday, "11:00", "Fri, Sep 4, 2026", 8),
        ]
        calls = fixtures
        selectedID = fixtures[0].id
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    var selectedCall: SampleCall { calls.first { $0.id == selectedID } ?? calls[0] }
    var groups: [String] { calls.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }
    var selectedTurn: Int { sampleTurns.last { Double($0.time) <= position }?.id ?? 0 }
    var captureBusy: Bool { [.starting, .recording, .saving, .saveFailed, .stopUnconfirmed].contains(capture) }
    var sourceTitle: String { longTitle ? "Sample application with a deliberately long name for layout review" : selectedCall.source }
    var appLevel: Double { applicationSignal ? (reduceMotion ? 0.58 : 0.27 + 0.48 * abs(sin(tick * 2.3))) : 0 }
    var micLevel: Double { microphoneSignal && microphoneAvailable && !microphoneMuted && !microphonePending ? (reduceMotion ? 0.8 : 0.4 + 0.5 * abs(sin(tick * 3.8))) : 0 }

    private func advance() {
        guard capture == .recording || playing else { return }
        tick += 0.1
        if capture == .recording && Int(tick * 10) % 10 == 0 { elapsed += 1 }
        if playing { position = min(position + 0.1, Double(selectedCall.minutes * 60)); if position >= Double(selectedCall.minutes * 60) { playing = false } }
    }

    func select(_ call: SampleCall) { selectedID = call.id; position = 29; playing = false }
    func setReading(_ state: ReadingState) {
        if let index = calls.firstIndex(where: { $0.id == selectedID }) { calls[index].state = state }
        playing = false
        onCaptureChange?()
    }
    func start() {
        if captureBusy { panelVisible = true; return }
        transition += 1; let token = transition
        microphoneMuted = false; microphonePending = false; elapsed = 0
        capture = .starting; panelVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard transition == token, capture == .starting else { return }
            capture = .recording
        }
    }
    func cancelStart() {
        guard capture == .starting else { return }
        transition += 1; capture = .idle; panelVisible = false
        notice = "Start cancelled · no sample audio created"
    }
    func toggleMicrophone() {
        guard capture == .recording, microphoneAvailable, !microphonePending else { return }
        microphonePending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if capture == .recording { microphoneMuted.toggle() }
            microphonePending = false
        }
    }
    func finish() {
        guard capture == .recording || capture == .saveFailed || capture == .stopUnconfirmed else { return }
        transition += 1; let token = transition
        capture = .saving; microphonePending = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard transition == token else { return }
            if simulateSaveFailure { capture = .saveFailed; panelVisible = true; return }
            calls.insert(.init("Google Chrome", "com.google.Chrome", "Today / Sep 8", "10:00", "Tue, Sep 8, 2026", max(1, elapsed / 60), state: .processing), at: 0)
            capture = .saved; panelVisible = false
            notice = "Recording saved · sample call added to Today"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if capture == .saved { capture = .idle }
            }
        }
    }
    func showCapture(_ state: CaptureState) {
        transition += 1; capture = state; microphonePending = false
        if state == .recording { elapsed = 252 }
        panelVisible = state != .idle
    }
}
