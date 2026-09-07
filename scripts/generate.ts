import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { Schema } from "effect";
import { format } from "oxfmt";
import { documentSchemas } from "../packages/contracts/src/document-schema.ts";
import { assertExchangeSchema } from "./contract-schema.ts";
import { generateSwift } from "./generate-swift.ts";

const rootPackage = await Bun.file("package.json").json();
const installed = await Bun.file("node_modules/effect/package.json").json();
const reference = await Bun.file("repos/effect/packages/effect/package.json").json();
if (
  installed.version !== rootPackage.devDependencies.effect ||
  reference.version !== installed.version
)
  throw new Error(
    "Contract generation requires matching pinned, installed and vendored Effect versions",
  );
for (const schema of Object.values(documentSchemas)) assertExchangeSchema(schema);
const document = Schema.toJsonSchemaDocument(Schema.Union(Object.values(documentSchemas)), {
  generateDescriptions: false,
});
if (document.dialect !== "draft-2020-12") throw new Error("Unsupported JSON Schema dialect");
const schemaSource =
  JSON.stringify(
    {
      $schema: "https://json-schema.org/draft/2020-12/schema",
      $id: "https://trigo.local/contracts/v1.schema.json",
      title: "TrigoV1",
      ...document.schema,
      $defs: document.definitions,
    },
    null,
    2,
  ) + "\n";
const formattedSchema = await format("schema.json", schemaSource);
if (formattedSchema.errors.length > 0)
  throw new Error("Generated JSON Schema could not be formatted");
const schemaText = formattedSchema.code;
const swift = generateSwift(document.definitions, Object.keys(documentSchemas));
const files: Record<string, string> = {
  "Sources/TrigoContracts/Resources/capture-master-profile.v1.json": await readFile(
    "packages/contracts/schema/capture-master-profile.v1.json",
    "utf8",
  ),
  "schema/v1.schema.json": schemaText,
  "Sources/TrigoContracts/Resources/v1.schema.json": schemaText,
  "Sources/TrigoContracts/GeneratedDocuments.swift": swift,
  "Sources/TrigoContracts/Resources/media-profile.v1.json": await readFile(
    "packages/contracts/schema/media-profile.v1.json",
    "utf8",
  ),
};
for (const [relative, content] of Object.entries(files)) {
  const target = `packages/contracts/${relative}`;
  if (process.argv.includes("--check")) {
    if ((await readFile(target, "utf8").catch(() => "")) !== content)
      throw new Error(`Generated artifact is stale: ${target}; run bun run contracts:generate`);
  } else {
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, content);
  }
}
