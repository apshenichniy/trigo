import { resolve } from "node:path";

export function nativeSigning(action: string, team: string | undefined, adHoc: boolean): string[] {
  if (adHoc) {
    if (team) {
      throw new Error("Unset TRIGO_SIGNING_TEAM when explicitly using --ad-hoc");
    }
    return ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"];
  }
  if (team) {
    if (!/^[A-Z0-9]{10}$/.test(team)) {
      throw new Error("TRIGO_SIGNING_TEAM must be a team identifier");
    }
    return [`DEVELOPMENT_TEAM=${team}`, "CODE_SIGN_IDENTITY=Apple Development"];
  }
  if (action === "run" || action === "install") {
    throw new Error(
      "Installed development requires TRIGO_SIGNING_TEAM; use --ad-hoc explicitly for disposable builds (rebuild permission continuity is not supported)",
    );
  }
  return ["CODE_SIGNING_ALLOWED=NO"];
}

export function installationDestination(
  applications: string,
  variant: string,
  worktree: string,
  local: boolean,
): string {
  if (variant !== "dev" && variant !== "personal") {
    throw new Error("Invalid app variant");
  }
  if (!/^[a-f0-9]{12}$/.test(worktree)) {
    throw new Error("Invalid worktree identity");
  }
  if (local && variant !== "dev") {
    throw new Error("Local installations require the dev variant");
  }
  const name = local ? `Trigo Local Dev ${worktree}` : variant === "dev" ? "Trigo Dev" : "Trigo";
  return resolve(applications, `${name}.app`);
}

export interface InstalledIdentity {
  readonly bundleId: string;
  readonly worktree: string;
  readonly requirement: string;
}

export function assertSupportedReplacement(
  previous: InstalledIdentity,
  candidate: InstalledIdentity,
  replaceWorktree: boolean,
  adHoc: boolean,
): void {
  if (previous.bundleId !== candidate.bundleId) {
    throw new Error("Refusing to replace an installation with another bundle identity");
  }
  if (previous.worktree !== candidate.worktree && !replaceWorktree) {
    throw new Error(
      "Installed app belongs to another worktree; select --replace-worktree explicitly after quitting it",
    );
  }
  if (!adHoc && previous.requirement !== candidate.requirement) {
    throw new Error(
      "Installed signing requirement changed; review this identity change before replacing the app manually",
    );
  }
}
