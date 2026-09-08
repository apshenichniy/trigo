import { Effect } from "effect";

import { storedByteHash, type FinalizeMasterUpload } from "@trigo/contracts";

import { invalidUpload, uploadStorage } from "./upload-errors.ts";

/** A bounded transport projection of the capture timeline; canonical interval JSON stays local. */
export const sourceStatesHash = Effect.fn("MasterUpload.validateSourceStates")(function* (
  input: FinalizeMasterUpload,
) {
  const binary = yield* Effect.try({
    try: () => atob(input.sourceStates.data),
    catch: () => invalidUpload("The source-state map must use canonical base64."),
  });
  if (
    binary.length !== Math.ceil(input.durationMs / 2) ||
    btoa(binary) !== input.sourceStates.data
  ) {
    return yield* invalidUpload("The source-state map must cover the exact closed duration.");
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < bytes.length; index++) {
    const byte = binary.charCodeAt(index);
    bytes[index] = byte;
    for (let half = 0; half < 2; half++) {
      const nibble = (byte >> (half * 4)) & 15;
      const microphone = nibble & 3;
      const application = nibble >> 2;
      if (index * 2 + half >= input.durationMs) {
        if (nibble !== 0) {
          return yield* invalidUpload("Source-state padding must be zero.");
        }
      } else if (microphone === 3 || (application !== 0 && application !== 2)) {
        return yield* invalidUpload("The source-state map contains an invalid source state.");
      }
    }
  }
  return yield* uploadStorage("source-state checksum", () => storedByteHash(bytes));
});
