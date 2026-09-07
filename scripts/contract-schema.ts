import { Schema } from "effect";
import type { SchemaAST } from "effect";

/** Reject lossy/best-effort generation before it can become a checked artifact. */
export function assertExchangeSchema(schema: Schema.Constraint): void {
  const visited = new Set<SchemaAST.AST>();
  function check(filter: SchemaAST.Check<unknown>): void {
    if (filter._tag === "FilterGroup") {
      for (const child of filter.checks) check(child);
    } else if (typeof filter.annotations?.toJsonSchema !== "function") {
      throw new Error("Exchange schema check has no JSON Schema representation");
    }
  }
  function visit(ast: SchemaAST.AST): void {
    if (visited.has(ast)) return;
    visited.add(ast);
    if (ast.encoding !== undefined)
      throw new Error("Exchange schemas cannot transform wire values");
    for (const filter of ast.checks ?? []) check(filter);
    switch (ast._tag) {
      case "String":
      case "Number":
      case "Boolean":
      case "Null":
      case "Literal":
        return;
      case "Arrays":
        for (const item of [...ast.elements, ...ast.rest]) visit(item);
        return;
      case "Objects":
        for (const field of ast.propertySignatures) visit(field.type);
        for (const index of ast.indexSignatures) {
          visit(index.parameter);
          visit(index.type);
        }
        return;
      case "Union":
        for (const member of ast.types) visit(member);
        return;
      default:
        throw new Error(`Unsupported Effect exchange schema node: ${ast._tag}`);
    }
  }
  visit(schema.ast);
}
