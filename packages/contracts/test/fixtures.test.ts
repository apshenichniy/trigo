import { readFileSync } from "node:fs";

import { expect, it } from "vitest";

import cases from "../fixtures/cases.json";
import { parseStored, validateArchive, type DocumentKind } from "../src/index.ts";
const read = (file: string) =>
  new Uint8Array(readFileSync(new URL(`../fixtures/${file}`, import.meta.url)));
for (const fixture of cases) {
  it(fixture.name, async () => {
    const bytes = read(fixture.document);
    const run = async () =>
      fixture.kind === "CallDocument"
        ? (
            await validateArchive(
              bytes,
              new Map(
                Object.entries(fixture.references).map(([id, file]) => [id, read(file as string)]),
              ),
            )
          ).call
        : parseStored(fixture.kind as DocumentKind, bytes);
    if (fixture.expected) {
      await expect(run()).rejects.toThrowError(fixture.expected);
    } else {
      expect(await run()).toEqual(JSON.parse(new TextDecoder().decode(bytes)));
    }
  });
}
