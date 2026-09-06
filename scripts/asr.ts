import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Console, Effect, Redacted, Schema } from "effect";
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/unstable/http";
import {
  AsrProbeErrorEnvelope,
  AsrProbeTranscriptionResponse,
  AsrProbeUploadResponse,
  inspectWaveObject,
  makeWaveHeader,
  selectedMediaProfile,
  type AsrProbeLanguageCode,
} from "../packages/contracts/src/index.ts";
import { cloudTargetFor, parseCloudStage, readCloudConfiguration } from "./cloud.ts";

type ProbeLanguage = AsrProbeLanguageCode;

class AsrProbeCliError extends Schema.TaggedError<AsrProbeCliError>()("AsrProbeCliError", {
  message: Schema.String,
  cause: Schema.optionalKey(Schema.Defect()),
}) {}
const isAsrProbeCliError = Schema.is(AsrProbeCliError);

function probeCliError(message: string, cause?: unknown): AsrProbeCliError {
  return new AsrProbeCliError(cause === undefined ? { message } : { message, cause });
}

const fixtures: Record<
  ProbeLanguage,
  {
    readonly voice: string;
    readonly microphone: string;
    readonly remoteA: string;
    readonly remoteB: string;
  }
> = {
  en: {
    voice: "Samantha",
    microphone: "Trigo local microphone marker one.",
    remoteA: "Trigo remote speaker alpha marker.",
    remoteB: "Trigo remote speaker beta marker.",
  },
  ru: {
    voice: "Milena",
    microphone: "Локальная метка микрофона Триго номер один.",
    remoteA: "Удалённый собеседник произносит метку альфа.",
    remoteB: "Другой удалённый фрагмент содержит метку бета.",
  },
  uk: {
    voice: "Lesya",
    microphone: "Локальна мітка мікрофона Тріго номер один.",
    remoteA: "Віддалений співрозмовник вимовляє мітку альфа.",
    remoteB: "Інший віддалений фрагмент містить мітку бета.",
  },
};

function run(program: string, args: readonly string[]): void {
  const result = spawnSync(program, [...args], { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${program} failed with status ${result.status}`);
}

function synthesize(voice: string, text: string, output: string, rate: number): void {
  run("say", ["-v", voice, "-r", String(rate), "-o", output, text]);
}

export function generateProbeFixture(language: ProbeLanguage, output: string): void {
  const fixture = fixtures[language];
  const directory = mkdtempSync(resolve(tmpdir(), `trigo-asr-${language}-`));
  const microphone = resolve(directory, "microphone.aiff");
  const remoteA = resolve(directory, "remote-a.aiff");
  const remoteB = resolve(directory, "remote-b.aiff");
  const raw = resolve(directory, "fixture.pcm");
  try {
    synthesize(fixture.voice, fixture.microphone, microphone, 180);
    synthesize(fixture.voice, fixture.remoteA, remoteA, 160);
    synthesize(fixture.voice, fixture.remoteB, remoteB, 215);

    run("ffmpeg", [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      microphone,
      "-i",
      remoteA,
      "-i",
      remoteB,
      "-filter_complex",
      "[0:a]aresample=16000,aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono,adelay=1000:all=1,apad,atrim=duration=18[mic];[1:a]aresample=16000,aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono,adelay=6000:all=1,apad,atrim=duration=18[a];[2:a]aresample=16000,aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono,adelay=12000:all=1,apad,atrim=duration=18[b];[a][b]amix=inputs=2:normalize=0,aformat=sample_fmts=s16:sample_rates=16000:channel_layouts=mono,apad,atrim=duration=18[app];[mic][app]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[out]",
      "-map",
      "[out]",
      "-ar",
      String(selectedMediaProfile.sampleRateHz),
      "-ac",
      String(selectedMediaProfile.channels.length),
      "-c:a",
      "pcm_s16le",
      "-f",
      "s16le",
      raw,
    ]);

    const audio = new Uint8Array(readFileSync(raw));
    const bytesPerFrame =
      selectedMediaProfile.channels.length * (selectedMediaProfile.bitsPerSample / 8);
    if (audio.byteLength % bytesPerFrame !== 0)
      throw new Error("Generated fixture is not aligned to the selected sample frame");
    const header = makeWaveHeader(audio.byteLength / bytesPerFrame);
    const wave = new Uint8Array(header.byteLength + audio.byteLength);
    wave.set(header);
    wave.set(audio, header.byteLength);
    const inspection = inspectWaveObject(wave);
    if (inspection.durationMs !== 18_000)
      throw new Error(
        `Generated fixture duration is ${inspection.durationMs} ms instead of 18000 ms`,
      );
    writeFileSync(output, wave, { mode: 0o600 });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function readOwnerToken(root: string): Redacted.Redacted<string> {
  const worktree = createHash("sha256").update(root).digest("hex").slice(0, 12);
  const service = `io.github.apshenichniy.trigo.dev.${worktree}.connection-token`;
  const result = spawnSync("security", ["find-generic-password", "-s", service, "-w"], {
    encoding: "utf8",
  });
  if (result.status !== 0 || result.stdout.trim() === "")
    throw new Error("The paired Trigo Dev owner token is unavailable in Keychain");
  return Redacted.make(result.stdout.trim());
}

const request = Effect.fn("AsrProbeCli.request")(function* <Success>(
  url: string,
  token: Redacted.Redacted<string>,
  method: "PUT" | "POST",
  successStatus: number,
  successSchema: Schema.Decoder<Success, never>,
  body?: Uint8Array,
) {
  let outgoing = method === "PUT" ? HttpClientRequest.put(url) : HttpClientRequest.post(url);
  outgoing = HttpClientRequest.acceptJson(HttpClientRequest.bearerToken(outgoing, token));
  if (method === "PUT") {
    outgoing = HttpClientRequest.setHeader(
      outgoing,
      "x-trigo-media-profile",
      selectedMediaProfile.id,
    );
    if (body !== undefined)
      outgoing = HttpClientRequest.bodyUint8Array(outgoing, body, selectedMediaProfile.contentType);
  }
  const response = yield* HttpClient.execute(outgoing).pipe(
    Effect.timeout("5 minutes"),
    Effect.mapError((cause) =>
      probeCliError(`Nova-3 probe request failed: ${method} ${url}`, cause),
    ),
  );
  const responseBody = yield* response.json.pipe(
    Effect.mapError((cause) =>
      probeCliError(
        `Nova-3 probe returned invalid JSON: HTTP ${response.status} ${method} ${url}`,
        cause,
      ),
    ),
  );
  if (response.status === successStatus) {
    const decoded = yield* Schema.decodeEffect(successSchema)(responseBody).pipe(
      Effect.mapError((cause) =>
        probeCliError(
          `Nova-3 probe returned an invalid success envelope: HTTP ${response.status} ${method} ${url}`,
          cause,
        ),
      ),
    );
    return { ok: true, status: response.status, body: decoded } as const;
  }
  const failure = yield* Schema.decodeUnknownEffect(AsrProbeErrorEnvelope)(responseBody).pipe(
    Effect.mapError((cause) =>
      probeCliError(
        `Nova-3 probe returned an invalid error envelope: HTTP ${response.status} ${method} ${url}`,
        cause,
      ),
    ),
  );
  return { ok: false, status: response.status, error: failure.error } as const;
});

const probe = Effect.fn("AsrProbeCli.probe")(function* (
  apiUrl: string,
  token: Redacted.Redacted<string>,
  languages: ReadonlyArray<ProbeLanguage>,
) {
  yield* Console.log(`Profile: ${selectedMediaProfile.id}`);
  yield* Console.log(
    `Request set: ${languages.length} controlled 18-second stereo fixture${languages.length === 1 ? "" : "s"}; no automatic retries.`,
  );
  for (const language of languages) {
    yield* Effect.acquireUseRelease(
      Effect.sync(() => mkdtempSync(resolve(tmpdir(), `trigo-asr-live-${language}-`))),
      (directory) =>
        Effect.gen(function* () {
          const fixturePath = resolve(directory, `${language}.wav`);
          yield* Effect.try({
            try: () => generateProbeFixture(language, fixturePath),
            catch: (cause) => probeCliError(`${language} fixture generation failed`, cause),
          });
          const bytes = yield* Effect.try({
            try: () => new Uint8Array(readFileSync(fixturePath)),
            catch: (cause) => probeCliError(`${language} fixture read failed`, cause),
          });
          const fixture = `two-source-${language}`;
          const url = `${apiUrl}/__trigo/asr-probe/${fixture}?language=${language}`;
          const upload = yield* request(url, token, "PUT", 201, AsrProbeUploadResponse, bytes);
          if (!upload.ok)
            return yield* probeCliError(
              `${language} fixture upload failed: HTTP ${upload.status} ${upload.error.code}`,
            );
          const result = yield* request(url, token, "POST", 200, AsrProbeTranscriptionResponse);
          if (!result.ok) {
            yield* Console.log(
              `${language}: HTTP ${result.status} ${result.error.code}; ${result.error.message}`,
            );
            return;
          }
          yield* Console.log(
            `${language}: accepted; bytes=${result.body.byteLength}; durationMs=${result.body.durationMs}; providerLatencyMs=${result.body.providerLatencyMs}; channels=${result.body.channelCount}; turns=${result.body.turnCount}; speakers=${result.body.speakerCount}`,
          );
        }),
      (directory) =>
        Effect.sync(() => {
          rmSync(directory, { recursive: true, force: true });
        }),
    );
  }
  yield* Console.log("Controlled results retained privately in dev R2.");
});

const main = Effect.gen(function* () {
  const root = yield* Effect.try({
    try: () => realpathSync(fileURLToPath(new URL("..", import.meta.url))),
    catch: (cause) => probeCliError("Cannot resolve the Trigo worktree", cause),
  });
  const [action, ...args] = process.argv.slice(2);
  if (action === "generate") {
    const languageIndex = args.indexOf("--language");
    const outputIndex = args.indexOf("--output");
    const language = languageIndex < 0 ? undefined : args[languageIndex + 1];
    const output = outputIndex < 0 ? undefined : args[outputIndex + 1];
    if ((language !== "en" && language !== "ru" && language !== "uk") || output === undefined)
      return yield* probeCliError("generate requires --language en|ru|uk and --output <path>");
    return yield* Effect.try({
      try: () => generateProbeFixture(language, resolve(output)),
      catch: (cause) => probeCliError("Fixture generation failed", cause),
    });
  }
  if (action !== "probe") return yield* probeCliError("Expected asr action: generate or probe");
  const stage = yield* Effect.try({
    try: () => parseCloudStage(args),
    catch: (cause) => probeCliError("Invalid cloud stage", cause),
  });
  if (stage !== "dev") return yield* probeCliError("Nova-3 probes may target only --stage dev");
  const languageIndexes = args.flatMap((value: string, index: number) =>
    value === "--language" ? [index] : [],
  );
  if (languageIndexes.length > 1)
    return yield* probeCliError("Pass at most one --language selector");
  const selectedLanguage =
    languageIndexes[0] === undefined ? undefined : args[languageIndexes[0] + 1];
  if (
    selectedLanguage !== undefined &&
    selectedLanguage !== "en" &&
    selectedLanguage !== "ru" &&
    selectedLanguage !== "uk"
  )
    return yield* probeCliError("Use --language en, --language ru, or --language uk");
  const languages: ReadonlyArray<ProbeLanguage> =
    selectedLanguage === undefined ? ["en", "ru", "uk"] : [selectedLanguage];
  const target = cloudTargetFor(stage);
  const configuration = yield* Effect.try({
    try: () => readCloudConfiguration(resolve(root, target.configPath), target),
    catch: (cause) => probeCliError("Cannot read the dev cloud configuration", cause),
  });
  if (configuration.apiUrl === undefined)
    return yield* probeCliError("The dev Cloud API URL is missing");
  const token = yield* Effect.try({
    try: () => readOwnerToken(root),
    catch: (cause) => probeCliError("Cannot read the paired Trigo Dev owner token", cause),
  });
  return yield* probe(configuration.apiUrl, token, languages);
}).pipe(
  Effect.provide(FetchHttpClient.layer),
  Effect.provideService(FetchHttpClient.RequestInit, { redirect: "error" }),
);

if (import.meta.main) {
  try {
    await Effect.runPromise(main);
  } catch (error) {
    console.error(
      isAsrProbeCliError(error)
        ? error.message
        : error instanceof Error
          ? error.message
          : String(error),
    );
    process.exitCode = 1;
  }
}
