import { Effect, Redacted, Schema } from "effect";
import { ownerHandoffTarget, readOwnerHandoff } from "./cloud-owner.ts";
import { cloudTargetFor, type CloudConfiguration } from "./cloud.ts";

class ProbeCredentialError extends Schema.TaggedError<ProbeCredentialError>()(
  "ProbeCredentialError",
  {
    message: Schema.String,
  },
) {}

/** Operator probes never read or create an installed application's Keychain items. */
export const readProbeCredential = Effect.fn("AsrProbe.readCredential")(function* (
  handoffPath: string,
  configuration: CloudConfiguration,
) {
  const handoff = yield* readOwnerHandoff(handoffPath, "dev");
  const expected = ownerHandoffTarget(cloudTargetFor("dev"), configuration.accountId);
  if (
    configuration.stage !== "dev" ||
    handoff.action === "revoke" ||
    handoff.target.accountId !== expected.accountId ||
    handoff.target.databaseName !== expected.databaseName ||
    handoff.target.deploymentIdentity !== expected.deploymentIdentity
  )
    return yield* new ProbeCredentialError({
      message: "The probe requires a token handoff for this dev deployment",
    });
  return Redacted.make(handoff.token);
});
