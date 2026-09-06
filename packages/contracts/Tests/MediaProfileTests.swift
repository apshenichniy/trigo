import Testing

@testable import TrigoContracts

@Test func mediaProfilePreservesChannelProvenance() throws {
  let profile = try MediaProfile.selected()
  #expect(
    profile.channels == [
      .init(index: 0, role: .microphone),
      .init(index: 1, role: .application),
    ])
  #expect(profile.interleaved)
  #expect(profile.assembly.missingFrames == "silence")
  #expect(profile.asr.speakerScope == "object-channel")
}

@Test func mediaProfileFitsTransportLimits() throws {
  let profile = try MediaProfile.selected()
  let frames = profile.frameCount(durationMs: profile.objectDurationMs)
  #expect(frames == 960_000)
  #expect(profile.waveByteLength(frameCount: frames) == profile.maxObjectBytes)
  #expect(profile.maxObjectBytes < profile.limits.uploadRequestBytes)
  #expect(4 * ((profile.maxObjectBytes + 2) / 3) == profile.limits.base64ObjectBytes)
  #expect(profile.limits.base64ObjectBytes < profile.limits.batchEnvelopeBytes)
}

@Test func mediaProfileCoversLongCallsWithoutClockDrift() throws {
  let profile = try MediaProfile.selected()
  #expect(profile.objectCount(durationMs: 3_600_000) == 60)
  #expect(profile.objectCount(durationMs: profile.maxCallDurationMs) == profile.maxObjectsPerCall)
  #expect(profile.frameCount(durationMs: 3_600_000) / profile.sampleRateHz == 3_600)
  #expect(profile.checkpointDurationMs == 2_000)
}
