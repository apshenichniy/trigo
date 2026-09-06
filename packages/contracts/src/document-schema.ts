import { Schema } from "effect";
import type { ErrorEnvelope } from "./generated/documents.d.ts";
import * as validators from "./generated/validators.mjs";

/** Effect boundary for the canonical generated ErrorEnvelope contract. */
export const ErrorEnvelopeSchema = Schema.declare<ErrorEnvelope>(
  (input): input is ErrorEnvelope => validators.ErrorEnvelope(input),
  { identifier: "ErrorEnvelope" },
);
