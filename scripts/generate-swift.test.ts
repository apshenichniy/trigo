import { Schema } from "effect";
import { expect, it } from "vitest";

import { documentSchemas } from "../packages/contracts/src/document-schema.ts";
import { assertExchangeSchema } from "./contract-schema.ts";
import { generateSwift } from "./generate-swift.ts";

it("requires representable Effect structure and checks before generation", () => {
  for (const schema of Object.values(documentSchemas)) {
    expect(() => assertExchangeSchema(schema)).not.toThrow();
  }
  expect(() =>
    assertExchangeSchema(Schema.declare((value): value is string => typeof value === "string")),
  ).toThrow("Unsupported Effect exchange schema node");
  expect(() =>
    assertExchangeSchema(Schema.String.check(Schema.makeFilter((value) => value === "x"))),
  ).toThrow("no JSON Schema representation");
  expect(() => assertExchangeSchema(Schema.FiniteFromString)).toThrow(
    "cannot transform wire values",
  );
});

it("fails explicitly when Swift generation cannot represent new schema capabilities", () => {
  expect(() => generateSwift({ Unsupported: { type: "string", format: "email" } }, [])).toThrow(
    "Unsupported Swift format",
  );
  expect(() => generateSwift({ Unsupported: { type: "string", not: { const: "x" } } }, [])).toThrow(
    "Unsupported Swift schema keyword",
  );
  expect(() =>
    generateSwift({ Unsupported: { anyOf: [{ type: "number" }, { type: "string" }] } }, []),
  ).toThrow("Unsupported Swift union");
  expect(() => generateSwift({ Unsupported: { $ref: "#/$defs/Missing" } }, [])).toThrow(
    "Unresolved Swift reference",
  );
});

it("qualifies wire fields that overlap generated decoder locals", () => {
  const source = generateSwift(
    {
      Wire: {
        type: "object",
        additionalProperties: false,
        properties: { container: { type: "string" } },
        required: ["container"],
      },
    },
    ["Wire"],
  );
  expect(source).toContain("self.container = try container.decode(");
  expect(source).toContain("try container.encode(self.container, forKey: .container)");
});
