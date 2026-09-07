import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import {
  artifactFingerprint,
  artifactReceiptMatches,
  buildCurrentArtifact,
  buildEnvironmentFingerprint,
} from "./build-reuse.ts";

afterEach(() => vi.unstubAllEnvs());

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "trigo-build-reuse-"));
  const artifact = join(directory, "App.app");
  const receipt = join(directory, "receipt.json");
  let input = "source-and-toolchain-one";
  let builds = 0;
  let verified = 0;
  const options = { artifact, receipt, identity: () => input, reuse: true };
  const build = () => {
    builds++;
    mkdirSync(artifact, { recursive: true });
    writeFileSync(join(artifact, "binary"), input);
  };
  const verify = () => {
    verified++;
    expect(readFileSync(join(artifact, "binary"), "utf8")).toBe(input);
  };
  return {
    directory,
    artifact,
    receipt,
    options,
    build,
    verify,
    change: () => {
      input = "source-and-toolchain-two";
    },
    counts: () => ({ builds, verified }),
  };
}

it("reuses a current verified artifact, then rebuilds after source/settings changes or artifact tampering", () => {
  const f = fixture();
  try {
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("built");
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("reused");
    expect(f.counts()).toEqual({ builds: 1, verified: 2 });
    f.change();
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("built");
    writeFileSync(join(f.artifact, "binary"), "stale binary");
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("built");
    rmSync(f.artifact, { recursive: true });
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("built");
    expect(f.counts()).toEqual({ builds: 4, verified: 5 });
  } finally {
    rmSync(f.directory, { recursive: true, force: true });
  }
});

it("retires a prior receipt before a fresh build failure and never verifies or executes its old artifact", () => {
  const f = fixture();
  try {
    buildCurrentArtifact(f.options, f.build, f.verify);
    expect(() =>
      buildCurrentArtifact(
        { ...f.options, reuse: false },
        () => {
          throw new Error("compiler failed");
        },
        f.verify,
      ),
    ).toThrow("compiler failed");
    expect(f.counts().verified).toBe(1);
    expect(artifactReceiptMatches(f.receipt, f.options.identity(), f.artifact)).toBe(false);
  } finally {
    rmSync(f.directory, { recursive: true, force: true });
  }
});

it("rejects sources changed during a build and receipts owned by another check invocation", () => {
  const f = fixture();
  try {
    expect(() =>
      buildCurrentArtifact(
        f.options,
        () => {
          f.change();
          f.build();
        },
        f.verify,
      ),
    ).toThrow("inputs changed");
    expect(artifactReceiptMatches(f.receipt, f.options.identity(), f.artifact)).toBe(false);
    buildCurrentArtifact({ ...f.options, owner: "parent-check" }, f.build, f.verify);
    expect(
      artifactReceiptMatches(f.receipt, f.options.identity(), f.artifact, "parent-check"),
    ).toBe(true);
    expect(
      artifactReceiptMatches(f.receipt, f.options.identity(), f.artifact, "standalone-check"),
    ).toBe(false);
  } finally {
    rmSync(f.directory, { recursive: true, force: true });
  }
});

it("rebuilds when an external compiler configuration cannot be covered by tracked input identity", () => {
  const f = fixture();
  try {
    buildCurrentArtifact(f.options, f.build, f.verify);
    vi.stubEnv("XCODE_XCCONFIG_FILE", "/external/config.xcconfig");
    expect(buildCurrentArtifact(f.options, f.build, f.verify)).toBe("built");
  } finally {
    rmSync(f.directory, { recursive: true, force: true });
  }
});

it("hashes build environment changes while ignoring only command bookkeeping", () => {
  const env = { DEVELOPER_DIR: "/Xcode", CUSTOM_BUILD_FLAG: "one", npm_lifecycle_event: "build" };
  const original = buildEnvironmentFingerprint(env);
  expect(
    buildEnvironmentFingerprint({
      ...env,
      npm_lifecycle_event: "install",
      TRIGO_CHECK_PARENT_SPAN_ID: "parent",
    }),
  ).toBe(original);
  expect(buildEnvironmentFingerprint({ ...env, CUSTOM_BUILD_FLAG: "two" })).not.toBe(original);
  expect(buildEnvironmentFingerprint({ ...env, DEVELOPER_DIR: "/OtherXcode" })).not.toBe(original);
});

it("rejects artifact symlinks to mutable data outside the verified bundle", () => {
  const f = fixture();
  try {
    f.build();
    writeFileSync(join(f.directory, "external"), "outside");
    symlinkSync("../external", join(f.artifact, "link"));
    expect(() => artifactFingerprint(f.artifact)).toThrow("escapes");
  } finally {
    rmSync(f.directory, { recursive: true, force: true });
  }
});
