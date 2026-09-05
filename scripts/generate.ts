import { mkdtemp, readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import standalone from "ajv/dist/standalone/index.js";
import { compile, type JSONSchema } from "json-schema-to-typescript";
const schemaPath = "packages/contracts/schema/v1.schema.json";
const schemaText = await readFile(schemaPath, "utf8");
const schema = JSON.parse(schemaText);
const ajv = new Ajv2020({
  strict: true,
  allowUnionTypes: true,
  code: { source: true, esm: true },
  allErrors: true,
});
addFormats(ajv);
ajv.addSchema(schema);
const names = Object.keys(schema.$defs);
const exports = Object.fromEntries(names.map((name) => [name, `${schema.$id}#/$defs/${name}`]));
const validators = standalone(ajv, exports);
const declarations = await compile(schema as JSONSchema, "TrigoV1", {
  bannerComment: "/* Generated from schema/v1.schema.json. Do not edit. */",
  unreachableDefinitions: true,
});
const output = await mkdtemp(join(tmpdir(), "trigo-generation-"));
try {
  const files: Record<string, string> = {
    "src/generated/validators.mjs": validators,
    "src/generated/validators.d.mts":
      names
        .map((name) => `export declare const ${name}: import("ajv").ValidateFunction;`)
        .join("\n") + "\n",
    "src/generated/documents.d.ts": declarations,
    "Sources/TrigoContracts/Resources/v1.schema.json": schemaText,
  };
  for (const [relative, content] of Object.entries(files)) {
    const target = join("packages/contracts", relative);
    const temporary = join(output, relative);
    await mkdir(join(temporary, ".."), { recursive: true });
    await writeFile(temporary, content);
    if (process.argv.includes("--check")) {
      if ((await readFile(target, "utf8").catch(() => "")) !== (await readFile(temporary, "utf8")))
        throw new Error(`Generated artifact is stale: ${target}; run bun run contracts:generate`);
    } else {
      await mkdir(join(target, ".."), { recursive: true });
      await writeFile(target, content);
    }
  }
} finally {
  await rm(output, { recursive: true, force: true });
}
