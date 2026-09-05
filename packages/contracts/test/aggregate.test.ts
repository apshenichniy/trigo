import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { validateArchive, storedByteHash } from "../src/index.ts";
const read = (name: string) =>
  new Uint8Array(readFileSync(new URL(`../fixtures/${name}.json`, import.meta.url)));
it("validates retained revisions and annotations against stored bytes", async () => {
  const refs = new Map([
    ["00000000-0000-4000-8000-000000000004", read("audio")],
    ["00000000-0000-4000-8000-000000000006", read("revision")],
    ["00000000-0000-4000-8000-000000000011", read("no-speech")],
  ]);
  await expect(validateArchive(read("call"), refs)).resolves.toBeDefined();
  refs.delete("00000000-0000-4000-8000-000000000006");
  await expect(validateArchive(read("call"), refs)).rejects.toThrow("reference");
});
it("hashes stored bytes rather than equivalent parsed JSON", async () => {
  expect(await storedByteHash(new TextEncoder().encode("abc"))).toBe(
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
  expect(await storedByteHash(new TextEncoder().encode('{"a":1}'))).not.toBe(
    await storedByteHash(new TextEncoder().encode('{ "a": 1 }')),
  );
});
it("rejects malformed and non-UTF-8 stored documents", async () => {
  const { readStoredDocument } = await import("../src/index.ts");
  await expect(readStoredDocument("TranscriptRevision", new Uint8Array([0xff]))).rejects.toThrow(
    "structure",
  );
  await expect(
    readStoredDocument("TranscriptRevision", new TextEncoder().encode("{")),
  ).rejects.toThrow("structure");
});
it("retains immutable source bytes independently of caller buffers", async () => {
  const { readStoredDocument } = await import("../src/index.ts");
  const source = read("revision");
  const stored = await readStoredDocument("TranscriptRevision", source);
  source.fill(0);
  const exposed = stored.storedBytes;
  exposed.fill(0);
  expect(stored.storedBytes).toEqual(read("revision"));
});
