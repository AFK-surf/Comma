// Archived threads as files (store.rs `// ── archive`): `<archive>/threads/<id>.jsonl.zst`, one entry per line as serde
// writes EntryRow (camelCase, fields in the struct's order, the skipped Nones left out), zstd level 3.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { type EntryRow, type Json, attachment, authorKind, quote } from "./rows.ts";

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
  return v;
}

/// An entry from an archive file, as serde reads EntryRow (null where an Option is: None).
export function archivedEntry(e: Json): EntryRow {
  const kind = e.kind;
  if (kind !== "message" && kind !== "edit") throw new Error(`unknown entry kind ${kind}`);
  if (!["person", "agent", "ember", "stillfail"].includes(e.authorKind)) throw new Error(`unknown author kind ${e.authorKind}`);
  const some = (v: Json) => (v === undefined || v === null ? undefined : v);
  return {
    agentIdentity: some(e.agentIdentity), thread: e.thread, n: e.n, kind, target: e.target ?? null, ts: e.ts ?? null,
    authorKind: authorKind(e.authorKind), author: e.author, text: e.text ?? null, attachments: (e.attachments ?? []).map(attachment),
    quotes: (e.quotes ?? []).map(quote), declared: e.declared ?? null, client: e.client ?? null, profile: e.profile ?? null,
    options: some(e.options), card: some(e.card), at: e.at,
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

/// What archive_thread writes: each entry and a newline.
export const archiveText = (entries: EntryRow[]): string => entries.map((e) => `${JSON.stringify(entryJson(e))}\n`).join("");
