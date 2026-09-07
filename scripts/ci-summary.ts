function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Missing CI result");
  return value as Record<string, unknown>;
}

export function assertCIResults(value: unknown): void {
  const needs = record(value);
  const plan = record(needs.plan);
  if (plan.result !== "success") throw new Error("Check selection/formatting did not succeed");
  const outputs = record(plan.outputs);
  if (outputs.server !== "true" && outputs.server !== "false")
    throw new Error("Missing server selection");
  if (typeof outputs.macos !== "string" || !["none", "smoke", "full"].includes(outputs.macos))
    throw new Error("Missing macOS selection");
  for (const [job, required] of [
    ["server", outputs.server === "true"],
    ["macos", outputs.macos !== "none"],
  ] as const) {
    const result = record(needs[job]).result;
    if (required ? result !== "success" : result !== "success" && result !== "skipped")
      throw new Error(
        `${job} checks ${required ? "were required and " : ""}did not succeed: ${String(result)}`,
      );
  }
}

if (import.meta.main) {
  assertCIResults(JSON.parse(process.env.TRIGO_CI_NEEDS ?? "null"));
  console.log("All selected checks completed successfully.");
}
