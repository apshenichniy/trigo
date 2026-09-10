/* oxlint-disable effecttsgo/async-function -- Disposable provider fixture consumes Web Streams at the native HTTP boundary. */
import { Effect } from "effect";
import { vi } from "vitest";

import { validateDocument } from "@trigo/contracts";

import { assemblyAIStereoProfile } from "../../../packages/contracts/src/asr-profile.ts";
import type { AssemblyAIClient } from "../src/assemblyai-client.ts";
import type { AssemblyAIJob } from "../src/assemblyai-response.ts";
import { fixtureRuntime, transcriptionCommand } from "./transcription-fixture.ts";

export const assemblyAICommand = () =>
  validateDocument("RequestTranscription", {
    ...transcriptionCommand(),
    profileId: assemblyAIStereoProfile.id,
  });

export function assemblyAIResponse(
  id = "provider-1",
  status: AssemblyAIJob["status"] = "completed",
) {
  const words = [
    { text: "Hello.", start: 100, end: 300, channel: "1", speaker: "A", confidence: 0.9 },
    { text: "Reply.", start: 400, end: 700, channel: "2", speaker: "A", confidence: 0.8 },
  ];
  return {
    id,
    status,
    audio_url: `https://cdn.eu.assemblyai.com/upload/${id}`,
    audio_duration: 1,
    audio_channels: 2,
    multichannel: true,
    speaker_labels: true,
    language_code: "en",
    language_detection: false,
    speech_model_used: "universal-2",
    punctuate: true,
    format_text: true,
    text: "Hello. Reply.",
    words,
  };
}

export const assemblyAIBytes = (value: unknown) => ({
  bytes: new TextEncoder().encode(JSON.stringify(value)),
  complete: true,
});

export function assemblyAIFixture() {
  let uploads = 0;
  const client = {
    upload: vi.fn<AssemblyAIClient["upload"]>((body, byteLength) =>
      Effect.promise(async () => {
        const reader = body.getReader();
        let consumed = 0;
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) {
            break;
          }
          consumed += chunk.value.byteLength;
        }
        if (consumed !== byteLength) {
          throw new Error("Incomplete fixture upload");
        }
        uploads++;
        return `https://cdn.eu.assemblyai.com/upload/provider-${uploads}`;
      }),
    ),
    submit: vi.fn<AssemblyAIClient["submit"]>((url) =>
      Effect.succeed({
        ...assemblyAIResponse(url.split("/").at(-1)),
        status: "queued" as const,
      }),
    ),
    get: vi.fn<AssemblyAIClient["get"]>((id) =>
      Effect.succeed(assemblyAIBytes(assemblyAIResponse(id))),
    ),
    find: vi.fn<AssemblyAIClient["find"]>(() => Effect.succeed("provider-1")),
    delete: vi.fn<AssemblyAIClient["delete"]>(() => Effect.void),
  } satisfies AssemblyAIClient;
  return { client, runtime: { ...fixtureRuntime(), ASSEMBLYAI: client } };
}
