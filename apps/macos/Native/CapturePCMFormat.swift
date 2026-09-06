import TrigoContracts

/// Capture arithmetic derives from the same validated profile consumed by the server.
extension MediaProfile {
  var captureFramesPerMs: Int { sampleRateHz / 1000 }
  var captureSamplesPerMs: Int { captureFramesPerMs * channels.count }
  var captureSamplesPerSecond: Int { sampleRateHz * channels.count }
  var captureBytesPerFrame: Int { channels.count * bitsPerSample / 8 }
  var captureBytesPerMs: Int { captureFramesPerMs * captureBytesPerFrame }
  var captureObjectPCMBytes: Int { maxObjectBytes - waveHeaderBytes }
}
