/** Parse wrapper options before any tool, file, credential or network operation. */
export function commandOptions(
  command: string,
  args: readonly string[],
  supported: Readonly<Record<string, "value" | "flag">>,
): ReadonlyMap<string, string | true> {
  const values = new Map<string, string | true>();
  for (let index = 0; index < args.length; index++) {
    const option = args[index]!;
    if (!Object.hasOwn(supported, option)) {
      throw new Error(
        `Unexpected ${command} argument: ${option}. Supported options: ${Object.keys(supported).join(", ") || "none"}`,
      );
    }
    if (values.has(option)) {
      throw new Error(`Pass ${option} at most once for ${command}`);
    }
    if (supported[option] === "flag") {
      values.set(option, true);
    } else {
      const value = args[++index];
      if (!value || value.startsWith("-")) {
        throw new Error(`Pass a value after ${option} for ${command}`);
      }
      values.set(option, value);
    }
  }
  return values;
}
