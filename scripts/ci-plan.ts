import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

export type CheckSelection = { server: boolean; macos: "none" | "smoke" | "full" };
const fullChecks = (): CheckSelection => ({ server: true, macos: "full" });

export function selectChecks(paths: readonly string[]): CheckSelection {
  if (!paths.length) {
    return fullChecks();
  }
  const selection: CheckSelection = { server: false, macos: "none" };
  for (const path of paths) {
    if (/^(?:README|AGENTS|CONTEXT)\.md$/.test(path) || /^docs\/[^\0]+\.md$/.test(path)) {
      continue;
    }
    if (path.startsWith("apps/macos/")) {
      selection.macos = "full";
    } else if (path.startsWith("apps/server/") || path.startsWith("infra/")) {
      selection.server = true;
      if (selection.macos === "none") {
        selection.macos = "smoke";
      }
    } else {
      // Includes contracts, scripts, dependency/tool pins, workflows and unknown areas.
      return fullChecks();
    }
  }
  return selection;
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid event object");
  }
  return value as Record<string, unknown>;
}

function sha(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{40}$/.test(value) || /^0+$/.test(value)) {
    throw new Error("Missing usable Git revision");
  }
  return value;
}

export function changedPaths(eventName: string, event: unknown, root = process.cwd()): string[] {
  const payload = object(event);
  const git = (args: string[]) =>
    execFileSync("git", args, { cwd: root, maxBuffer: 16 * 1024 * 1024 }).toString();
  let base: string;
  let head: string;
  if (eventName === "pull_request") {
    const pullRequest = object(payload.pull_request);
    head = sha(object(pullRequest.head).sha);
    base = git(["merge-base", sha(object(pullRequest.base).sha), head]).trim();
  } else if (eventName === "push") {
    base = sha(payload.before);
    head = sha(payload.after);
  } else {
    throw new Error(`No verified comparison for event ${eventName}`);
  }
  // Disabling rename detection reports both the deleted old path and added new
  // path, preserving dependency selection across moves out of a component.
  return git(["diff", "--name-only", "-z", "--no-renames", base, head, "--"])
    .split("\0")
    .filter(Boolean);
}

export function ciPlan(
  eventName: string,
  event: unknown,
  selective: boolean,
  root = process.cwd(),
) {
  let paths: string[] = [];
  let fallback: string | null = null;
  try {
    paths = changedPaths(eventName, event, root);
  } catch (error) {
    fallback = error instanceof Error ? error.message : "Unable to determine changed paths";
  }
  const proposed = fallback ? fullChecks() : selectChecks(paths);
  return {
    version: 1,
    event: eventName,
    selective,
    fallback,
    paths,
    proposed,
    selected: selective ? proposed : fullChecks(),
  };
}

if (import.meta.main) {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  const plan = ciPlan(
    process.env.GITHUB_EVENT_NAME ?? "local",
    eventPath ? JSON.parse(readFileSync(eventPath, "utf8")) : {},
    process.env.TRIGO_SELECTIVE_CHECKS === "true",
  );
  mkdirSync(".local", { recursive: true });
  writeFileSync(".local/ci-plan.json", `${JSON.stringify(plan, null, 2)}\n`);
  console.log(JSON.stringify(plan, null, 2));
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `server=${plan.selected.server}\nmacos=${plan.selected.macos}\n`,
    );
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `## Check selection\n\nSelective mode: **${plan.selective ? "enabled" : "bootstrap (full checks)"}**. ` +
        `Server: **${plan.selected.server}**; macOS: **${plan.selected.macos}**. ` +
        `${plan.paths.length} changed paths. ${plan.fallback ? "Comparison unavailable; using full checks." : ""}\n`,
    );
  }
}
