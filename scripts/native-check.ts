import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

import {
  artifactReceiptMatches,
  buildCurrentArtifact,
  nativeBuildIdentity,
  supportsBuildReuse,
} from "./build-reuse.ts";
import {
  assertNativeTestOutput,
  exactTestFilter,
  nativeTestName,
  parseNativeTests,
  planNativeTests,
  type NativeSuite,
} from "./native-suites.ts";
import { timed, timedRun, timingEnvironment, timingRunId } from "./timing.ts";
import { toolOutput } from "./toolchain.ts";

export const swiftPackages = [
  { path: "packages/contracts", configuration: "debug" },
  { path: "apps/macos", configuration: "release" },
] as const;

export function lockedSwiftArguments(path: string): string[] {
  return [
    "--package-path",
    path,
    "--cache-path",
    resolve(".local/SwiftPMCache"),
    "--force-resolved-versions",
    "--skip-update",
  ];
}

export function swiftTestBuild(path: string, configuration: string, execute = timedRun): void {
  // Always check current sources, including exact build-cache hits. Match testable
  // imports in Release as well as Debug before any --skip-build execution/discovery.
  execute(`${path} ${configuration} build tests`, [
    "swift",
    "build",
    ...lockedSwiftArguments(path),
    "--configuration",
    configuration,
    "--build-tests",
    "-Xswiftc",
    "-enable-testing",
  ]);
}

export function swiftContractTests(execute = timedRun): void {
  swiftTestBuild("packages/contracts", "debug", execute);
  execute("packages/contracts debug test", [
    "swift",
    "test",
    ...lockedSwiftArguments("packages/contracts"),
    "--configuration",
    "debug",
    "--skip-build",
  ]);
}

const nativeArtifact = () => resolve("apps/macos/.build/release/TrigoNativePackageTests.xctest");
const nativeIdentity = () =>
  nativeBuildIdentity("native-tests-release", ["--build-tests", "-Xswiftc", "-enable-testing"]);

function buildNativeTests(build: () => void): string {
  const receipt = resolve(`.local/build-receipts/native-${randomUUID()}.json`);
  buildCurrentArtifact(
    {
      receipt,
      artifact: nativeArtifact(),
      identity: nativeIdentity(),
      reuse: false,
      owner: timingRunId(),
    },
    build,
    () => {
      if (!existsSync(nativeArtifact())) {
        throw new Error("Current native test bundle is missing");
      }
    },
  );
  return receipt;
}

export function canReuseNativeTests(receipt: string): boolean {
  return (
    supportsBuildReuse() &&
    artifactReceiptMatches(receipt, nativeIdentity()(), nativeArtifact(), timingRunId())
  );
}

function runNativeGroup(phase: string, command: string[], resourceTest?: string): void {
  timed(
    phase,
    () => {
      const result = spawnSync(command[0]!, command.slice(1), {
        encoding: "utf8",
        maxBuffer: 16 * 1024 * 1024,
        env: timingEnvironment(),
      });
      process.stdout.write(result.stdout ?? "");
      process.stderr.write(result.stderr ?? "");
      if (result.error) {
        throw result.error;
      }
      if (result.status !== 0) {
        throw new Error(`${phase} failed (${result.status ?? result.signal})`);
      }
      assertNativeTestOutput(`${result.stdout}\n${result.stderr}`, resourceTest);
    },
    "release",
  );
}

const nativeOperations = {
  execute: timedRun,
  prepareNative: buildNativeTests,
  discover: toolOutput,
  test: runNativeGroup,
};

export function nativeTests(
  options: { suite?: NativeSuite; filter?: string } = {},
  operations = nativeOperations,
): string {
  const receipt = operations.prepareNative(() =>
    swiftTestBuild("apps/macos", "release", operations.execute),
  );
  const args = [...lockedSwiftArguments("apps/macos"), "--configuration", "release"];
  const tests = parseNativeTests(
    operations.discover(["swift", "test", ...args, "list", "--skip-build"]),
  );
  const plan = planNativeTests(tests, options.suite ?? "all", options.filter);
  console.log(
    `Native selection: ${options.suite ?? "all"}; ${plan.reduce((count, group) => count + group.tests.length, 0)}/${tests.length} discovered tests; ${plan.length} process groups.`,
  );
  for (const group of plan) {
    const resourceTest = group.suite === "resource" ? nativeTestName(group.tests[0]!) : undefined;
    operations.test(
      `Native ${group.suite}${resourceTest ? ` ${resourceTest}` : ""}`,
      ["swift", "test", ...args, "--skip-build", "--filter", exactTestFilter(group.tests)],
      resourceTest,
    );
  }
  return receipt;
}

export function swiftTests(operations = nativeOperations): string {
  swiftContractTests(operations.execute);
  return nativeTests({}, operations);
}
