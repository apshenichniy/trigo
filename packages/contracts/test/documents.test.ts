import { expect, it } from "vitest";
import { validateDocument } from "../src/index.ts";
it("rejects incompatible schema versions before import", () => {
  expect(() => validateDocument("CallDocument", { schemaVersion: 2 })).toThrowError("structure");
});
