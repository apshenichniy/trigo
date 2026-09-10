import type { TranscriptRevision } from "@trigo/contracts";

export interface TimedTranscriptWord {
  readonly text: string;
  readonly startMs: number;
  readonly endMs: number;
  readonly confidence: number | null;
  readonly label: string | null;
}

/** Retain reported alignment and flag conflicts without letting an outlier poison later words. */
export function alignTranscriptWords(
  words: readonly TimedTranscriptWord[],
  start: number,
  end: number,
) {
  const uncertain = new Set<number>();
  let furthest: { index: number; endMs: number } | undefined;
  for (const [index, word] of words.entries()) {
    if (!Number.isSafeInteger(word.startMs) || !Number.isSafeInteger(word.endMs)) {
      throw new RangeError("Provider word timing exceeds representable milliseconds");
    }
    if (word.endMs < word.startMs || word.startMs < start || word.endMs > end) {
      uncertain.add(index);
      continue;
    }
    if (furthest !== undefined && word.startMs < furthest.endMs) {
      uncertain.add(furthest.index);
      uncertain.add(index);
    }
    if (furthest === undefined || word.endMs > furthest.endMs) {
      furthest = { index, endMs: word.endMs };
    }
  }
  return words.map(({ label, ...word }, index) => ({
    label,
    normalized: { ...word, ...(uncertain.has(index) ? { timingUncertain: true as const } : {}) },
  }));
}

export function followsTranscriptPause(
  previous: TranscriptRevision["turns"][number]["words"][number] | undefined,
  next: TranscriptRevision["turns"][number]["words"][number],
) {
  return (
    previous !== undefined &&
    previous.timingUncertain !== true &&
    next.timingUncertain !== true &&
    next.startMs - previous.endMs > 1_200
  );
}

/** Interleave available channel heads by playback time without reordering a
 * channel's provider text when its alignment runs backward. */
export function interleaveTrackTurns(turns: readonly TranscriptRevision["turns"][number][]) {
  const tracks = new Map<
    string,
    { turns: TranscriptRevision["turns"][number][]; cursor: number }
  >();
  for (const turn of turns) {
    let track = tracks.get(turn.trackId);
    if (track === undefined) {
      track = { turns: [], cursor: 0 };
      tracks.set(turn.trackId, track);
    }
    track.turns.push(turn);
  }
  const compare = (
    left: TranscriptRevision["turns"][number],
    right: TranscriptRevision["turns"][number],
  ) =>
    left.startMs - right.startMs ||
    left.endMs - right.endMs ||
    left.trackId.localeCompare(right.trackId);
  const ordered: TranscriptRevision["turns"][number][] = [];
  while (ordered.length < turns.length) {
    let selected:
      | { turn: TranscriptRevision["turns"][number]; track: { cursor: number } }
      | undefined;
    for (const track of tracks.values()) {
      const turn = track.turns[track.cursor];
      if (turn !== undefined && (selected === undefined || compare(turn, selected.turn) < 0)) {
        selected = { turn, track };
      }
    }
    if (selected === undefined) {
      break;
    }
    ordered.push(selected.turn);
    selected.track.cursor += 1;
  }
  return ordered;
}
