import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { Schema } from "effect";

import { makeAsrMasterHeader } from "../apps/server/src/asr-master.ts";
import { AsrProbeLanguage } from "../packages/contracts/src/index.ts";

const Language = Schema.Literals(["en", "ru", "uk", "silence"]);
type Language = Schema.Schema.Type<typeof Language>;
const markers = ["alpha", "bravo", "charlie"] as const;

const phrases: Record<
  Exclude<Language, "silence">,
  ReadonlyArray<{
    readonly voice: string;
    readonly role: "microphone" | "application";
    readonly startMs: number;
    readonly text: (marker: number) => string;
  }>
> = {
  en: [
    {
      voice: "Samantha",
      role: "microphone",
      startMs: 1000,
      text: (marker) =>
        `Local microphone. Checkpoint ${markers[marker]}. The garden is quiet today.`,
    },
    {
      voice: "Daniel",
      role: "application",
      startMs: 5500,
      text: (marker) =>
        `Remote Daniel. Checkpoint ${markers[marker]}. I will review the blue folder.`,
    },
    {
      voice: "Karen",
      role: "application",
      startMs: 12000,
      text: (marker) =>
        `Remote Karen. Checkpoint ${markers[marker]}. We can finish the report tomorrow.`,
    },
  ],
  ru: [
    {
      voice: "Milena",
      role: "microphone",
      startMs: 1000,
      text: (marker) =>
        `Локальный микрофон. Метка ${["альфа", "браво", "чарли"][marker]}. Сегодня в саду тихо.`,
    },
    {
      voice: "Milena",
      role: "application",
      startMs: 5500,
      text: (marker) =>
        `Удалённый собеседник. Метка ${["альфа", "браво", "чарли"][marker]}. Я проверю синюю папку.`,
    },
    {
      voice: "Milena",
      role: "application",
      startMs: 12000,
      text: (marker) =>
        `Удалённый источник. Метка ${["альфа", "браво", "чарли"][marker]}. Мы закончим отчёт завтра.`,
    },
  ],
  uk: [
    {
      voice: "Lesya",
      role: "microphone",
      startMs: 1000,
      text: (marker) =>
        `Локальний мікрофон. Мітка ${["альфа", "браво", "чарлі"][marker]}. Сьогодні в саду тихо.`,
    },
    {
      voice: "Lesya",
      role: "application",
      startMs: 5500,
      text: (marker) =>
        `Віддалений співрозмовник. Мітка ${["альфа", "браво", "чарлі"][marker]}. Я перевірю синю папку.`,
    },
    {
      voice: "Lesya",
      role: "application",
      startMs: 12000,
      text: (marker) =>
        `Віддалене джерело. Мітка ${["альфа", "браво", "чарлі"][marker]}. Ми закінчимо звіт завтра.`,
    },
  ],
};

function run(program: string, args: readonly string[]): void {
  const child = spawnSync(program, [...args], { stdio: "inherit" });
  if (child.error) {
    throw child.error;
  }
  if (child.status !== 0) {
    throw new Error(`${program} failed with status ${child.status}`);
  }
}

/** Three 20-second blocks allow long masters to expose unique middle/final source offsets. */
export function generateMasterTemplate(language: Language, output: string): void {
  const directory = mkdtempSync(join(tmpdir(), "trigo-master-fixture-"));
  try {
    const bytes = new Uint8Array(68 + 60_000 * 64);
    bytes.set(makeAsrMasterHeader());
    const events: Array<{
      block: number;
      marker: string;
      voice: string;
      role: string;
      channel: number;
      startMs: number;
      endMs: number;
      text: string;
    }> = [];
    if (language !== "silence") {
      for (const [block, marker] of markers.entries()) {
        for (const [speaker, phrase] of phrases[language].entries()) {
          const aiff = join(directory, `${block}-${speaker}.aiff`);
          const pcmPath = join(directory, `${block}-${speaker}.pcm`);
          const text = phrase.text(block);
          run("say", ["-v", phrase.voice, "-r", "175", "-o", aiff, text]);
          run("ffmpeg", [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            aiff,
            "-ar",
            "16000",
            "-ac",
            "1",
            "-f",
            "s16le",
            pcmPath,
          ]);
          const pcm = readFileSync(pcmPath);
          const frames = pcm.byteLength / 2;
          const speechMs = frames / 16;
          if (speechMs > 6000 || phrase.startMs + speechMs > 20_000) {
            throw new Error(
              `Controlled ${language}/${marker}/${phrase.voice} speech exceeds its gap budget`,
            );
          }
          const channel = phrase.role === "microphone" ? 0 : 1;
          const startMs = block * 20_000 + phrase.startMs;
          const offset = 68 + startMs * 64 + channel * 2;
          for (let frame = 0; frame < frames; frame += 1) {
            bytes[offset + frame * 4] = pcm[frame * 2] ?? 0;
            bytes[offset + frame * 4 + 1] = pcm[frame * 2 + 1] ?? 0;
          }
          events.push({
            block,
            marker,
            voice: phrase.voice,
            role: phrase.role,
            channel,
            startMs,
            endMs: startMs + speechMs,
            text,
          });
        }
      }
    }
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, bytes, { mode: 0o600 });
    writeFileSync(
      output + ".json",
      JSON.stringify(
        {
          schemaVersion: 1,
          language: language === "silence" ? AsrProbeLanguage.make("en") : language,
          kind: language === "silence" ? "digital-silence" : "controlled-synthetic-speech",
          profile: "caf-lpcm-s16le-16000-stereo-v1",
          layout: "twenty-second-blocks-start-middle-final-v1",
          durationMs: 60_000,
          byteLength: bytes.byteLength,
          sha256: createHash("sha256").update(bytes).digest("hex"),
          events,
        },
        null,
        2,
      ) + "\n",
      { mode: 0o600 },
    );
    console.log(
      `${language}: generated a 60-second controlled master template (${bytes.byteLength} bytes)`,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

if (import.meta.main) {
  const language = Schema.decodeUnknownSync(Language)(process.argv[2]);
  const output = process.argv[3];
  if (output === undefined) {
    throw new Error("Usage: bun scripts/asr-master-fixtures.ts en|ru|uk|silence <output.caf>");
  }
  generateMasterTemplate(language, resolve(output));
}
