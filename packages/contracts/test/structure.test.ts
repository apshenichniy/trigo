import addFormats from "ajv-formats";
import { Ajv2020 } from "ajv/dist/2020.js";
import { Schema, Struct } from "effect";
import { expect, it } from "vitest";

import corpus from "../fixtures/structure-cases.json";
import emitted from "../schema/v1.schema.json";
import { documentSchemas } from "../src/document-schema.ts";
import { validateStructure } from "../src/index.ts";

const kind = Schema.decodeUnknownSync(Schema.Literals(Struct.keys(documentSchemas)));
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
ajv.addSchema(emitted);
const emittedValidators = Object.fromEntries(
  Object.keys(documentSchemas).map((name) => [
    name,
    ajv.compile({ $ref: `${emitted.$id}#/$defs/${name}` }),
  ]),
);

for (const fixture of corpus) {
  it(`structural parity: ${fixture.name}`, () => {
    const name = kind(fixture.kind);
    const value: unknown = JSON.parse(fixture.json);
    const decode = () => validateStructure(name, value);
    const validator = emittedValidators[name];
    if (validator === undefined) {
      throw new Error("Missing emitted validator");
    }
    expect(validator(value)).toBe(fixture.valid);
    if (fixture.valid) {
      expect(decode()).toEqual(value);
    } else {
      expect(decode).toThrow("structure");
    }
  });
}

it("rejects non-JSON numeric inputs in the Effect boundary", () => {
  const fixture = corpus.find((item) => item.kind === "CallDocument" && item.valid);
  if (!fixture) {
    throw new Error("Missing fixture");
  }
  for (const number of [NaN, Infinity, -Infinity]) {
    expect(() =>
      validateStructure("CallDocument", { ...JSON.parse(fixture.json), documentVersion: number }),
    ).toThrow("structure");
  }
});
