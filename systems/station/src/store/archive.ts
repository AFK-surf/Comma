// Archived threads as files (store.rs `// ── archive`): `<archive>/threads/<id>.jsonl.zst`, one entry per line as serde
// writes EntryRow (camelCase, fields in the struct's order, the skipped Nones left out), zstd level 3.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { type EntryRow, type Json, attachment, authorKind, quote, storedDeliverToSlots, storedMilestones } from "./rows.ts";

export const threadFile = (archiveDir: string, thread: number): string => join(archiveDir, "threads", `${thread}.jsonl.zst`);

/// write_compressed: a file compressed with zstd, written aside first, then renamed into place.
export function writeCompressed(path: string, text: string): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, zstdCompressSync(Buffer.from(text, "utf8"), { params: { [constants.ZSTD_c_compressionLevel]: 3 } }));
  renameSync(tmp, path);
}

/// An entry as serde writes EntryRow: agentIdentity, client, profile, options and card left out when None.
export function entryJson(e: EntryRow): Record<string, Json> {
  const v: Record<string, Json> = {};
  if (e.agentIdentity !== undefined) v.agentIdentity = e.agentIdentity;
  Object.assign(v, {
    thread: e.thread, n: e.n, kind: e.kind, target: e.target, ts: e.ts, authorKind: e.authorKind, author: e.author,
    text: e.text, attachments: e.attachments.map(attachment), quotes: e.quotes.map(quote), declared: e.declared,
  });
  if (e.client !== null) v.client = e.client;
  if (e.profile !== null) v.profile = e.profile;
  if (e.options !== undefined) v.options = e.options;
  if (e.card !== undefined) v.card = e.card;
  v.at = e.at;
  if (e.milestones !== undefined) v.milestones = e.milestones;
  if (e.visibleToSlots !== undefined) v.visibleToSlots = e.visibleToSlots;
  return v;
}

/// An entry from an archive file, as serde reads EntryRow (null where an Option is: None).
export function archivedEntry(e: Json): EntryRow {
  const kind = e.kind;
  if (kind !== "message" && kind !== "edit" && kind !== "milestone") throw new Error(`unknown entry kind ${kind}`);
  if (!["person", "agent", "ember", "stillfail"].includes(e.authorKind)) throw new Error(`unknown author kind ${e.authorKind}`);
  const some = (v: Json) => (v === undefined || v === null ? undefined : v);
  const vis = storedDeliverToSlots(e.visibleToSlots);
  return {
    agentIdentity: some(e.agentIdentity), thread: e.thread, n: e.n, kind, target: e.target ?? null, ts: e.ts ?? null,
    authorKind: authorKind(e.authorKind), author: e.author, text: e.text ?? null, attachments: (e.attachments ?? []).map(attachment),
    quotes: (e.quotes ?? []).map(quote), declared: e.declared ?? null, client: e.client ?? null, profile: e.profile ?? null,
    options: some(e.options), card: some(e.card), at: e.at, milestones: storedMilestones(e.milestones),
    ...(vis !== undefined ? { visibleToSlots: vis } : {}),
  };
}

/// A thread's archive file as entries (fails as std::fs::read does when it is not there).
export function readArchive(path: string): EntryRow[] {
  const text = zstdDecompressSync(readFileSync(path)).toString("utf8");
  return text
    .split("\n")
    .map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l))
    .filter((l) => l !== "")
    .map((l) => archivedEntry(JSON.parse(l)));
}

/// Bounded reverse reader for archived JSONL threads: locates `beforeN` via O(log N)
/// binary search on strictly monotonic `entry.n` over line-byte offsets without decoding
/// the full file, then decodes backwards at most `maxDecode` entries.
export function readArchiveBackwards(
  path: string,
  beforeN: number | bigint,
  maxDecode: number,
  stop?: (entry: EntryRow) => boolean,
): { entries: EntryRow[]; decoded: number; exhausted: boolean; scannedMinN: number | null } {
  if (maxDecode <= 0) return { entries: [], decoded: 0, exhausted: false, scannedMinN: null };
  const buf = zstdDecompressSync(readFileSync(path));
  // Index non-empty line [start, end) byte ranges in a single O(bytes) scan without JSON.parse.
  const lines: [number, number][] = [];
  let start = 0;
  for (let i = 0; i <= buf.length; i++) {
    if (i === buf.length || buf[i] === 0x0a) {
      let end = i;
      if (end > start && buf[end - 1] === 0x0d) end--;
      if (end > start) lines.push([start, end]);
      start = i + 1;
    }
  }
  if (lines.length === 0) return { entries: [], decoded: 0, exhausted: true, scannedMinN: null };

  let decoded = 0;
  const decodeLine = (idx: number): EntryRow => {
    decoded++;
    const [s, e] = lines[idx]!;
    return archivedEntry(JSON.parse(buf.subarray(s, e).toString("utf8")));
  };

  let right = lines.length - 1;
  const cache = new Map<number, EntryRow>();

  if (beforeN !== Number.MAX_SAFE_INTEGER && beforeN < 9223372036854775807n) {
    // O(log N) binary search for the rightmost line with strictly monotonic `entry.n < beforeN`
    // (never relies on timestamps and does not consume the `maxDecode` page-scan budget).
    let lo = 0;
    let hi = lines.length - 1;
    let best = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const entry = cache.get(mid) ?? decodeLine(mid);
      cache.set(mid, entry);
      if (entry.n < beforeN) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    right = best;
  }

  if (right < 0) return { entries: [], decoded, exhausted: true, scannedMinN: null };

  const collected: EntryRow[] = [];
  let exhausted = true;
  let scannedMinN: number | null = null;
  let pageScanned = 0;
  for (let i = right; i >= 0; i--) {
    if (pageScanned >= maxDecode) {
      exhausted = false;
      break;
    }
    let entry = cache.get(i);
    if (!entry) {
      entry = decodeLine(i);
    }
    if (entry.n >= beforeN) continue;
    pageScanned++;
    scannedMinN = scannedMinN === null ? entry.n : Math.min(scannedMinN, entry.n);
    collected.push(entry);
    if (stop && stop(entry)) {
      exhausted = i === 0;
      break;
    }
  }
  return { entries: collected.reverse(), decoded, exhausted, scannedMinN };
}

/// What archive_thread writes: each entry and a newline.
export const archiveText = (entries: EntryRow[]): string => entries.map((e) => `${JSON.stringify(entryJson(e))}\n`).join("");
