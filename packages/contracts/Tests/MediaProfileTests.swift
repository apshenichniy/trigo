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
  #expect(profile.assembly.missingFrames == .silence)
  #expect(profile.asr.speakerScope == .objectChannel)
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

@Test func selectedMasterProfileIsGeneratedAndIndependentOfProbeInput() throws {
  let master = try CaptureMasterProfile.selected()
  let probe = try MediaProfile.selected()
  #expect(master.id == "caf-lpcm-s16le-16000-stereo-v1")
  #expect(master.container == "caf")
  #expect(master.contentType == "audio/x-caf")
  #expect(master.microphoneChannel == 0 && master.applicationChannel == 1)
  #expect(master.maxMasterBytes == 68 + 10_800_000 * 64)
  #expect(master.maxMasterBytes > master.maxRangeBytes)
  #expect(master.maxRangeBytes == probe.limits.uploadRequestBytes)
  #expect(master.maxCommitDurationMs == 1000)
  #expect(probe.asr.requestContentType == .wave)
  var invalid = master
  invalid.maxRangeBytes += 1
  #expect(throws: ContractError.structure) {
    try Contract.decode(CaptureMasterProfile.self, bytes: Contract.encode(invalid))
  }
}
