import { expect, it } from "vitest";
import {
  frameCountForDuration,
  inspectWaveObject,
  makeWaveHeader,
  objectCountForDuration,
  selectedMediaProfile,
  waveByteLength,
} from "../src/index.ts";

it("fixes two logical sources to stable stereo channel provenance", () => {
  expect(selectedMediaProfile.channels).toEqual([
    { index: 0, role: "microphone" },
    { index: 1, role: "application" },
  ]);
  expect(selectedMediaProfile.interleaved).toBe(true);
  expect(selectedMediaProfile.assembly.missingFrames).toBe("silence");
  expect(selectedMediaProfile.asr.speakerScope).toBe("object-channel");
});

it("writes and inspects the canonical independently decodable WAVE header", () => {
  const frameCount = frameCountForDuration(2_000);
  const header = makeWaveHeader(frameCount);
  const object = new Uint8Array(waveByteLength(frameCount));
  object.set(header);

  expect(inspectWaveObject(object)).toEqual({
    frameCount: 32_000,
    durationMs: 2_000,
    byteLength: 128_044,
  });
});

it("rejects a WAVE object with a source-mapping format mismatch", () => {
  const frameCount = frameCountForDuration(2_000);
  const object = new Uint8Array(waveByteLength(frameCount));
  object.set(makeWaveHeader(frameCount));
  new DataView(object.buffer).setUint16(22, 1, true);

  expect(() => inspectWaveObject(object)).toThrow("does not match the selected profile");
});

it("keeps every complete object below upload and Batch envelope limits", () => {
  const frames = frameCountForDuration(selectedMediaProfile.objectDurationMs);
  expect(frames).toBe(960_000);
  expect(waveByteLength(frames)).toBe(selectedMediaProfile.maxObjectBytes);
  expect(selectedMediaProfile.maxObjectBytes).toBeLessThan(
    selectedMediaProfile.limits.uploadRequestBytes,
  );
  expect(4 * Math.ceil(selectedMediaProfile.maxObjectBytes / 3)).toBe(
    selectedMediaProfile.limits.base64ObjectBytes,
  );
  expect(selectedMediaProfile.limits.base64ObjectBytes).toBeLessThan(
    selectedMediaProfile.limits.batchEnvelopeBytes,
  );
});

it("represents one- and three-hour calls without truncation or accumulated clock drift", () => {
  expect(objectCountForDuration(3_600_000)).toBe(60);
  expect(objectCountForDuration(selectedMediaProfile.maxCallDurationMs)).toBe(
    selectedMediaProfile.maxObjectsPerCall,
  );
  expect(frameCountForDuration(3_600_000) / selectedMediaProfile.sampleRateHz).toBe(3_600);
  expect(selectedMediaProfile.checkpointDurationMs).toBe(2_000);
});
