import Foundation
import Testing

@testable import TrigoNative

@Test func captureSourceResolutionIsFailClosedAndPinsTheApplicationInstance() throws {
  let chrome = CaptureSource(
    applicationName: "Controlled Chrome",
    bundleID: "com.google.Chrome",
    processID: 42,
    windowID: 12,
    windowTitle: "Fixture",
    processLaunchDate: Date(timeIntervalSince1970: 100)
  )
  let other = CaptureSource(
    applicationName: "Other",
    bundleID: "test.other",
    processID: 99,
    windowID: 13,
    windowTitle: "Other",
    processLaunchDate: Date(timeIntervalSince1970: 200)
  )
  let granted = CapturePermissions(screenAudio: true, microphone: true)
  let pinned = try CaptureSourceResolver.resolve(
    permissions: granted,
    frontmostPID: 42,
    ownPID: 1,
    windows: [other, chrome]
  )
  #expect(pinned == chrome)
  #expect(
    pinned.matches(
      processID: 42,
      bundleID: "com.google.Chrome",
      launchDate: chrome.processLaunchDate
    )
  )
  #expect(!pinned.matches(processID: 42, bundleID: "com.google.Chrome", launchDate: Date()))
  #expect(throws: CaptureStartFailure.screenAudioPermission) {
    try CaptureSourceResolver.resolve(
      permissions: .init(screenAudio: false, microphone: true),
      frontmostPID: 42,
      ownPID: 1,
      windows: [chrome]
    )
  }
  #expect(throws: CaptureStartFailure.microphonePermission) {
    try CaptureSourceResolver.resolve(
      permissions: .init(screenAudio: true, microphone: false),
      frontmostPID: 42,
      ownPID: 1,
      windows: [chrome]
    )
  }
  #expect(throws: CaptureStartFailure.unsupportedSource) {
    try CaptureSourceResolver.resolve(
      permissions: granted,
      frontmostPID: 777,
      ownPID: 1,
      windows: [chrome]
    )
  }
  #expect(throws: CaptureStartFailure.unsupportedSource) {
    try CaptureSourceResolver.resolve(
      permissions: granted,
      frontmostPID: 42,
      ownPID: 42,
      windows: [chrome]
    )
  }
}
