import { spawnSync } from "node:child_process";
export function run(
  command: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): void {
  const result = spawnSync(command[0]!, command.slice(1), { stdio: "inherit", ...options });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${command.join(" ")} failed (${result.status ?? result.signal})`);
  }
}
