// Background jobs as the pages read them (the Rust station's jobs.rs `shown`, `output_at`, `tail`; admin/views.rs
// `open_jobs`; admin/mod.rs GET /jobs, /jobs/:id, /jobs/:id/log). What a job is comes from its record: the station's
// hub, which runs them, keeps it current, so a read gives the state it last wrote.
import { closeSync, fstatSync, openSync, readSync, statSync } from "node:fs";
import type { Viewer } from "../mesh/credential.ts";
import { setLang } from "./spoken.ts";
import * as store from "./store.ts";
import type { Json, JobRow, Store } from "./store.ts";
import { HttpError, chats } from "./views.ts";
import type { Lang } from "../ops/i18n.ts";

/// How much of a log `tail` reads at most.
const LOG_BYTES = 64 * 1024;
/// How many of a job's notices the pages get with it.
const NOTICES_SHOWN = 20;

/// JobRow as serde writes it (the token skipped, `sessionKey` as `session`).
function jobJson(j: JobRow): Json {
  return {
    id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, state: j.state, pgid: j.pgid,
    exitCode: j.exitCode, startedAt: j.startedAt, endedAt: j.endedAt, restarts: j.restarts, log: j.log, watch: j.watch,
  };
}

/// shown: a job as the pages show it: its record, what it said lately (newest first) and when its output last grew.
export function shown(s: Store, job: JobRow): Json {
  const v = jobJson(job);
  v.notices = store.jobNotices(s, job.id, NOTICES_SHOWN);
  v.outputAt = outputAt(job.log);
  return v;
}

/// output_at: when a log last grew (ms), if it has anything in it.
export function outputAt(path: string): number | null {
  try {
    const meta = statSync(path, { bigint: true });
    if (meta.size === 0n || meta.mtimeNs < 0n) return null;
    return Number(meta.mtimeNs / 1_000_000n);
  } catch {
    return null;
  }
}

/// tail: the last `lines` lines of a log, from at most its last LOG_BYTES; "" when it does not read.
export function tail(path: string, lines: number): string {
  let file: number;
  try {
    file = openSync(path, "r");
  } catch {
    return "";
  }
  let bytes: Buffer;
  try {
    let size = 0;
    try {
      size = fstatSync(file).size;
    } catch {
      // metadata failing: from the start.
    }
    const from = Math.max(0, size - LOG_BYTES);
    const chunks: Buffer[] = [];
    const piece = Buffer.alloc(64 * 1024);
    try {
      for (let at = from; ; ) {
        const n = readSync(file, piece, 0, piece.length, at);
        if (n === 0) break;
        chunks.push(Buffer.from(piece.subarray(0, n)));
        at += n;
      }
    } catch {
      // read_to_end failing keeps what it read.
    }
    bytes = Buffer.concat(chunks);
  } finally {
    closeSync(file);
  }
  const all = rustLines(new TextDecoder("utf-8").decode(bytes));
  return all.slice(Math.max(0, all.length - lines)).join("\n");
}

/// str::lines: split at \n (a \r before it goes too); no last empty line.
export function rustLines(text: string): string[] {
  if (text === "") return [];
  const parts = text.split("\n");
  const ended = parts.at(-1) === "";
  if (ended) parts.pop();
  return parts.map((l, i) => (i < parts.length - 1 || ended) && l.endsWith("\r") ? l.slice(0, -1) : l);
}

/// GET /jobs (views.rs `open_jobs`): the jobs still up (running, or a service being started again), newest first, each
/// with the chat it is in as the viewer's list has it (`chat`: its id, title and whether it is archived).
export function openJobs(s: Store, viewer: Viewer, lang: Lang): Json[] {
  setLang(lang);
  const open = store.listJobs(s, null).filter((j) => j.state === "running" || (j.port !== null && j.state === "exited"));
  if (open.length === 0) return [];
  // An archived chat first, so a listed one showing the same session wins; a chat that is the session's own wins
  // over one it only takes part in.
  const found = new Map<string, [boolean, Json]>();
  const rows: [boolean, Json][] = [...chats(s, viewer, true).map((c): [boolean, Json] => [true, c]), ...chats(s, viewer, false).map((c): [boolean, Json] => [false, c])];
  for (const [archived, chat] of rows) {
    const shownChat = { id: chat.id ?? null, title: chat.title ?? null, archived };
    for (const agent of Array.isArray(chat.agents) ? chat.agents : []) {
      const key = agent?.key;
      if (typeof key !== "string") continue;
      const own = chat.session === key;
      const was = found.get(key);
      if (own || was === undefined || !was[0]) found.set(key, [own, shownChat]);
    }
  }
  return open.map((j) => {
    const v = shown(s, j);
    const chat = found.get(j.sessionKey);
    if (chat !== undefined) v.chat = chat[1];
    return v;
  });
}

/// GET /jobs/:id: a background job (a web service's own page finds its port by it).
export function job(s: Store, id: string): Json {
  const j = store.getJob(s, id);
  if (j === null) throw new HttpError(404, `no job ${id}`);
  return shown(s, j);
}

/// GET /jobs/:id/log: a job's last output (`lines`, default 200, from 1 to 1000), and that `/events` follows it.
export function jobLog(s: Store, id: string, lines: string | undefined): Json {
  const j = store.getJob(s, id);
  if (j === null) throw new HttpError(404, `no job ${id}`);
  const n = Math.min(Math.max(parseUsize(lines) ?? 200, 1), 1000);
  return { text: tail(j.log, n), outputAt: outputAt(j.log), follows: true, state: j.state };
}

/// `str::parse::<usize>`: digits with a + at most, no bigger than a usize; null otherwise.
export function parseUsize(text: string | undefined): number | null {
  if (text === undefined || !/^\+?\d+$/.test(text)) return null;
  const n = BigInt(text.replace(/^\+/, ""));
  return n > 18446744073709551615n ? null : Number(n);
}
