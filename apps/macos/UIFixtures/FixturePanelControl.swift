import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import TrigoContracts

@testable import TrigoNative

/// Only synthetic input and boundary faults are controllable. Product commands
/// still originate in the native menu/panel and run through the real coordinator.
@MainActor final class FixturePanelControl {
  enum Command: String, Codable {
    case bothSignals, applicationOnly, microphoneOnly, silence
    case microphoneLost, microphoneReturned
    case holdAudio, releaseAudio, holdStart, releaseStart
    case holdSave, releaseSave, failNextSave, failStops, allowStops
  }
  private struct Envelope: Decodable {
    let schemaVersion: Int
    let sequence: Int
    let command: Command
  }
  let application = FixtureCaptureTransport(role: .application, emitsAudio: true)
  let microphone = FixtureCaptureTransport(role: .microphone, emitsAudio: true)
  let queue = DispatchQueue(label: "trigo.ui-fixture.panel-audio")
  var microphoneAvailable = true
  private(set) var sequence = 0
  private(set) var commands: [[String: Any]] = []
  private(set) var failure: String?
  private let root: URL
  private var timer: Timer?
  private var audioHeld = false
  private var saveHeld = false
  private var saveGate: CheckedContinuation<Void, Never>?
  private var failSave = false
  private(set) var saveCalls = 0
  var waitingForSave: Bool { saveGate != nil }

  init(root: URL) {
    self.root = root
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.readCommand() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func beforeSave() async -> Bool {
    saveCalls += 1
    if saveHeld { await withCheckedContinuation { saveGate = $0 } }
    let fail = failSave
    failSave = false
    return fail
  }

  private func readCommand() {
    let file = root.appendingPathComponent("control.json")
    guard FileManager.default.fileExists(atPath: file.path), failure == nil else { return }
    do {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard file.resolvingSymlinksInPath() == file, values.isRegularFile == true,
        let size = values.fileSize, size <= 4096
      else { throw FixtureFailure.invalidConfiguration }
      let bytes = try Data(contentsOf: file)
      guard bytes.count <= 4096 else { throw FixtureFailure.invalidConfiguration }
      let command = try JSONDecoder().decode(Envelope.self, from: bytes)
      guard command.schemaVersion == 1 else { throw FixtureFailure.invalidConfiguration }
      if command.sequence <= sequence { return }
      guard command.sequence == sequence + 1, command.sequence <= 128 else {
        throw FixtureFailure.invalidConfiguration
      }
      apply(command.command)
      sequence = command.sequence
      commands.append(["sequence": sequence, "command": command.command.rawValue])
    } catch { failure = "Invalid isolated fixture control" }
  }

  private func apply(_ command: Command) {
    switch command {
    case .bothSignals: application.amplitude = 0.35; microphone.amplitude = 0.2
    case .applicationOnly: application.amplitude = 0.35; microphone.amplitude = 0
    case .microphoneOnly: application.amplitude = 0; microphone.amplitude = 0.2
    case .silence: application.amplitude = 0; microphone.amplitude = 0
    case .microphoneLost: microphoneAvailable = false
    case .microphoneReturned: microphoneAvailable = true
    case .holdAudio:
      guard !audioHeld else { return }
      application.pauseAudio(); microphone.pauseAudio()
      queue.suspend()
      audioHeld = true
    case .releaseAudio:
      guard audioHeld else { return }
      queue.resume()
      audioHeld = false
      application.resumeAudio(); microphone.resumeAudio()
    case .holdStart: application.holdStart = true
    case .releaseStart: application.releaseStart()
    case .holdSave: saveHeld = true
    case .releaseSave:
      saveHeld = false
      saveGate?.resume(); saveGate = nil
    case .failNextSave: failSave = true
    case .failStops: application.failsStop = true
    case .allowStops: application.failsStop = false
    }
  }
}

@MainActor final class FixtureCaptureTransport: CaptureTransport {
  let role: MediaSourceRole
  let emitsAudio: Bool
  var amplitude: Float
  var holdStart = false
  var failsStop = false
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private(set) var emittedBuffers = 0
  private(set) var failure: String?
  private(set) var running = false
  var waitingForStart: Bool { startGate != nil }
  private var startGate: CheckedContinuation<Void, Never>?
  private var sink: CaptureStreamSink?
  private var timer: Timer?
  private var audioPaused = false
  private var frameIndex = 0

  init(role: MediaSourceRole = .application, emitsAudio: Bool = false) {
    self.role = role
    self.emitsAudio = emitsAudio
    amplitude = role == .application ? 0.35 : 0.2
  }

  func addCaptureOutput(
    _ output: any SCStreamOutput,
    type: SCStreamOutputType,
    queue: DispatchQueue
  ) throws {
    guard let sink = output as? CaptureStreamSink else { throw FixtureFailure.forbiddenAdapter }
    self.sink = sink
  }

  func startCapture() async throws {
    startCalls += 1
    running = true
    resumeAudio()
    if holdStart {
      await withCheckedContinuation { startGate = $0 }
      // Model a native Start acknowledgement arriving after its first Stop.
      running = true
      resumeAudio()
    }
  }

  func releaseStart() {
    holdStart = false
    startGate?.resume(); startGate = nil
  }

  func stopForRetirement() async throws {
    stopCalls += 1
    if failsStop { throw FixtureFailure.invalidAudio }
    running = false
    pauseAudio()
  }

  func pauseAudio() {
    audioPaused = true
    timer?.invalidate(); timer = nil
  }

  func resumeAudio() {
    audioPaused = false
    guard emitsAudio, running, timer == nil else { return }
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.emit() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func emit() {
    guard running, !audioPaused, let sink else { return }
    do {
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      let sample = try makeSample(time: now)
      _ = sink.enqueue(sample, role: role, streamID: ObjectIdentifier(self), deliveredAt: now)
      emittedBuffers += 1
    } catch { failure = "Synthetic PCM construction failed" }
  }

  private func makeSample(time: CMTime) throws -> CMSampleBuffer {
    let frames = 800
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let samples = pcm.floatChannelData?[0]
    else { throw FixtureFailure.invalidAudio }
    pcm.frameLength = AVAudioFrameCount(frames)
    let frequency = role == .application ? 440.0 : 880.0
    for index in 0..<frames {
      samples[index] =
        amplitude * Float(sin(2 * .pi * frequency * Double(frameIndex + index) / 16_000))
    }
    frameIndex += frames
    var description: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: format.streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &description
      ) == noErr
    else { throw FixtureFailure.invalidAudio }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 16_000),
      presentationTimeStamp: time,
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        formatDescription: description,
        sampleCount: frames,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sample
      ) == noErr, let sample,
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sample,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: pcm.audioBufferList
      ) == noErr
    else { throw FixtureFailure.invalidAudio }
    return sample
  }
}
