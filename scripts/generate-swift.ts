import { Schema } from "effect";
import type { JsonSchema } from "effect";

const object = Schema.decodeUnknownSync(Schema.Record(Schema.String, Schema.Unknown));
const strings = Schema.decodeUnknownSync(Schema.Array(Schema.String));
const nodes = Schema.decodeUnknownSync(Schema.Array(Schema.Record(Schema.String, Schema.Unknown)));
const supported = new Set([
  "type",
  "$ref",
  "properties",
  "required",
  "additionalProperties",
  "propertyNames",
  "anyOf",
  "enum",
  "const",
  "pattern",
  "format",
  "minimum",
  "maximum",
  "minLength",
  "maxLength",
  "minItems",
  "maxItems",
  "items",
]);

/** Deliberately bounded compiler: new schema capabilities must be implemented and tested explicitly. */
export function generateSwift(
  definitions: JsonSchema.Definitions,
  kinds: readonly string[],
): string {
  function check(node: JsonSchema.JsonSchema): void {
    for (const key of Object.keys(node)) {
      if (!supported.has(key)) {
        throw new Error(`Unsupported Swift schema keyword: ${key}`);
      }
    }
    if (node.format !== undefined && node.format !== "date-time") {
      throw new Error(`Unsupported Swift format: ${JSON.stringify(node.format)}`);
    }
  }
  function type(node: JsonSchema.JsonSchema): string {
    check(node);
    if (typeof node.$ref === "string") {
      const name = node.$ref.replace(/^#\/\$defs\//, "");
      if (!definitions[name]) {
        throw new Error(`Unresolved Swift reference: ${node.$ref}`);
      }
      return name;
    }
    if (node.anyOf) {
      const members = nodes(node.anyOf);
      const nonNull = members.filter((member) => member.type !== "null");
      if (members.length === 2 && nonNull.length === 1 && nonNull[0]) {
        return `${type(nonNull[0])}?`;
      }
      if (
        members.length === 4 &&
        ["string", "number", "boolean", "null"].every((value) =>
          members.some((member) => member.type === value),
        )
      ) {
        return "JSONScalar";
      }
      throw new Error(
        "Unsupported Swift union; add an explicit representation before changing the contract",
      );
    }
    if (node.type === "string") {
      return "String";
    }
    if (node.type === "integer") {
      return "Int";
    }
    if (node.type === "number") {
      return Array.isArray(node.enum) && node.enum.every(Number.isSafeInteger) ? "Int" : "Double";
    }
    if (node.type === "boolean") {
      return "Bool";
    }
    if (node.type === "array") {
      return `[${type(object(node.items))}]`;
    }
    if (node.type === "object" && !node.properties) {
      if (node.propertyNames) {
        type(object(node.propertyNames));
      }
      return `[String: ${type(object(node.additionalProperties))}]`;
    }
    throw new Error(`Unsupported or anonymous Swift schema: ${JSON.stringify(node)}`);
  }
  const declarations = Object.entries(definitions).map(([name, node]) => {
    if (!/^[A-Za-z][A-Za-z0-9]*$/.test(name)) {
      throw new Error(`Invalid Swift type name: ${name}`);
    }
    check(node);
    if (!node.properties) {
      return `public typealias ${name} = ${type(node)}`;
    }
    if (node.type !== "object" || node.additionalProperties !== false) {
      throw new Error(`Unsupported Swift object: ${name}`);
    }
    const properties = object(node.properties);
    const required = strings(node.required ?? []);
    const fields = Object.entries(properties).map(([key, value]) => {
      if (!/^[a-z][A-Za-z0-9]*$/.test(key)) {
        throw new Error(`Invalid Swift property: ${name}.${key}`);
      }
      const wireType = type(object(value));
      const optional = !required.includes(key);
      if (optional && wireType.endsWith("?")) {
        throw new Error(`Unsupported optional nullable Swift property: ${name}.${key}`);
      }
      return { key, wireType, optional, type: optional ? `${wireType}?` : wireType };
    });
    if (
      new Set(required).size !== required.length ||
      required.some((key) => !(key in properties))
    ) {
      throw new Error(`Invalid required keys: ${name}`);
    }
    return `public struct ${name}: ${kinds.includes(name) ? "ContractDocument, " : ""}Codable, Equatable, Sendable {
${kinds.includes(name) ? `  public static let documentKind = "${name}"\n` : ""}${fields.map((field) => `  public var ${field.key}: ${field.type}`).join("\n")}
  public init(
${fields.map((field) => `    ${field.key}: ${field.type}${field.optional ? " = nil" : ""}`).join(",\n")}
  ) {
${fields.map((field) => `    self.${field.key} = ${field.key}`).join("\n")}
  }
  enum CodingKeys: String, CodingKey {
${fields.map((field) => `    case ${field.key}`).join("\n")}
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
${fields
  .map((field) =>
    field.optional
      ? `    self.${field.key} =\n      try container.contains(.${field.key})\n      ? container.decode(${field.wireType}.self, forKey: .${field.key}) : nil`
      : `    self.${field.key} = try container.decode(\n      ${field.type}.self,\n      forKey: .${field.key}\n    )`,
  )
  .join("\n")}
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
${fields
  .map((field) => {
    const method = field.optional ? "encodeIfPresent" : "encode";
    const line = `    try container.${method}(self.${field.key}, forKey: .${field.key})`;
    return line.length <= 100
      ? line
      : `    try container.${method}(
      self.${field.key},
      forKey: .${field.key}
    )`;
  })
  .join("\n")}
  }
}`;
  });
  return `// Generated from src/document-schema.ts via Effect JSON Schema. Do not edit.
// Decoding through Contract enforces constraints and rejects unknown properties.
// Strings retain wire UUID/date spelling. Required nullable fields encode explicit null.
import Foundation

enum GeneratedContract {
  static let documentKinds = [
${kinds.map((kind) => `    "${kind}",`).join("\n")}
  ]
}

${declarations.join("\n\n")}\n`;
}
