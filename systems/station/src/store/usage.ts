// What the agents spent, as the station records it (the Rust station's store/usage.rs): one row per model call, with the
// turn it was in, whom that turn worked for, in which thread and on which profile. The Store's usage methods call these.
import type { DatabaseSync } from "node:sqlite";
import { type Json, STILLFAIL_SURFACE } from "./rows.ts";

/// A model call read from a transcript. Tokens as the provider bills them.
export type UsageCall = {
  id: string; at: number; model: string | null; subagent: boolean; fast: boolean; input: number; cacheRead: number;
  cacheWrite: number; cacheWriteLong: number; output: number;
};

/// How far a transcript has been read, and for which session (null: none of the station's).
export type UsageFile = { session: string | null; offset: number; model: string | null };

/// What a call was for: the turn it was in, and whom that worked for, where, on what.
export type UsageFor = { turn: string | null; person: string | null; thread: number | null; profile: string | null };

/// A turn as usage takes it: when it started, and whom it worked for.
export type UsageTurn = { id: string; startedAt: number; of: UsageFor };

/// The calls of one day (in the asker's time zone) for one thread, person, profile and model, added up.
export type UsageGroup = {
  day: string; session: string; thread: number | null; person: string | null; profile: string | null; runtime: string;
  model: string | null; fast: boolean; calls: number; input: number; cacheRead: number; cacheWrite: number;
  cacheWriteLong: number; output: number;
};

/// Stands for i64::MIN as a turn's start: before every call.
const EARLIEST = Number.MIN_SAFE_INTEGER;

/// usage_files: every transcript read for usage so far, by path.
export function usageFiles(db: DatabaseSync): Map<string, UsageFile> {
  const rows = db.prepare("SELECT path, session, offset, model FROM usage_files").all() as Json[];
  return new Map(rows.map((r) => [r.path, { session: r.session, offset: r.offset, model: r.model }]));
}

/// record_usage: a transcript's calls read up to `file.offset`, each with what it was for; a call recorded before keeps
/// its row (its output grown). How many were new. Run in a transaction by the caller.
export function recordUsage(db: DatabaseSync, path: string, file: UsageFile, runtime: string, calls: [UsageCall, UsageFor][]): number {
  let added = 0;
  if (file.session !== null) {
    const insert = db.prepare(
      `INSERT INTO usage (id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
       ON CONFLICT (id) DO UPDATE SET output = MAX(output, excluded.output)`,
    );
    const known = db.prepare("SELECT 1 FROM usage WHERE id = ?");
    for (const [c, of] of calls) {
      const was = known.get(c.id) !== undefined;
      insert.run(
        c.id, c.at, file.session, of.turn, of.thread, of.person, of.profile, runtime, c.model, c.subagent ? 1 : 0, c.fast ? 1 : 0,
        c.input, c.cacheRead, c.cacheWrite, c.cacheWriteLong, c.output,
      );
      if (!was) added++;
    }
  }
  db.prepare(
    `INSERT INTO usage_files (path, session, offset, model) VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT (path) DO UPDATE SET session = excluded.session, offset = excluded.offset, model = excluded.model`,
  ).run(path, file.session, file.offset, file.model);
  return added;
}

/// usage_active_sessions: sessions whose transcripts may have grown since `since`: a turn running, or ended since then.
export function usageActiveSessions(db: DatabaseSync, since: number): string[] {
  return (db.prepare("SELECT DISTINCT session_key FROM turns WHERE ended_at IS NULL OR ended_at >= ?").all(since) as Json[]).map((r) => r.session_key);
}

/// usage_turns: a session's turns, oldest first, each with whom it worked for. Turns from before stations said so are
/// worked out: a turn that answered messages is for the first person whose message it took, in that message's thread;
/// any other goes on with the work of the one before. What is still unknown is the session's: its creator, its own chat,
/// its profile.
export function usageTurns(db: DatabaseSync, session: string): UsageTurn[] {
  const row = db.prepare("SELECT created_by, profile FROM sessions WHERE key = ?").get(session) as Json;
  const creator: string | null = row ? row.created_by : null;
  const profile: string = row ? row.profile : "";
  const homeRow = db
    .prepare("SELECT id FROM threads WHERE home = ?1 UNION ALL SELECT thread FROM (SELECT thread FROM thread_sessions WHERE session = ?1 ORDER BY joined_at LIMIT 1) LIMIT 1")
    .get(session) as Json;
  const home: number | null = homeRow ? homeRow.id : null;
  const turns = db.prepare("SELECT id, kind, started_at, profile, person, thread FROM turns WHERE session_key = ? ORDER BY started_at").all(session) as Json[];
  // The people's messages the session took, as they were delivered (only needed for turns from before).
  const delivered: [number, string, number][] = turns.some((t) => t.person === null)
    ? (
        db
          .prepare(
            `SELECT d.delivered_at AS at, CASE WHEN t.surface = ?2 THEN e.author ELSE 'slack:' || ts.connect || ':' || e.author END AS who, e.thread AS thread
             FROM deliveries d JOIN entries e ON e.thread = d.thread AND e.n = d.n JOIN threads t ON t.id = d.thread
             JOIN thread_sessions ts ON ts.thread = d.thread AND ts.session = d.session
             WHERE d.session = ?1 AND d.delivered_at IS NOT NULL AND e.author_kind = 'person' ORDER BY d.delivered_at`,
          )
          .all(session, STILLFAIL_SURFACE) as Json[]
      ).map((r) => [r.at, r.who, r.thread])
    : [];
  const out: UsageTurn[] = [];
  let next = 0;
  turns.forEach((t, n) => {
    const end = n + 1 < turns.length ? turns[n + 1].started_at : Number.MAX_SAFE_INTEGER;
    while (next < delivered.length && delivered[next]![0] < t.started_at) next++;
    const candidate = delivered[next];
    const first = t.kind === "input" && candidate !== undefined && candidate[0] < end ? candidate : null;
    const previous = out.at(-1)?.of ?? null;
    const person = t.person ?? first?.[1] ?? previous?.person ?? creator;
    const thread = t.thread ?? first?.[2] ?? previous?.thread ?? home;
    out.push({ id: t.id, startedAt: t.started_at, of: { turn: t.id, person, thread, profile: t.profile ?? profile } });
  });
  if (out.length === 0) out.push({ id: "", startedAt: EARLIEST, of: { turn: null, person: creator, thread: home, profile } });
  return out;
}

/// usage_groups: the calls from `from` until `to` (ms), added up by day in the asker's time zone (`utcOffsetMin`) and
/// by thread, person, profile and model.
export function usageGroups(db: DatabaseSync, from: number, to: number, utcOffsetMin: number): UsageGroup[] {
  return (
    db
      .prepare(
        `SELECT strftime('%Y-%m-%d', (at + ?3 * 60000) / 1000, 'unixepoch') AS day, session, thread, person, profile, runtime, model, fast,
           COUNT(*) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read, SUM(cache_write) AS cache_write,
           SUM(cache_write_long) AS cache_write_long, SUM(output) AS output
         FROM usage WHERE at >= ?1 AND at < ?2
         GROUP BY day, session, thread, person, profile, runtime, model, fast`,
      )
      .all(from, to, utcOffsetMin) as Json[]
  ).map((r) => ({
    day: r.day, session: r.session, thread: r.thread, person: r.person, profile: r.profile, runtime: r.runtime, model: r.model,
    fast: r.fast !== 0 && r.fast !== null, calls: r.calls, input: r.input, cacheRead: r.cache_read, cacheWrite: r.cache_write,
    cacheWriteLong: r.cache_write_long, output: r.output,
  }));
}

/// usage_since: when the earliest call recorded was made.
export function usageSince(db: DatabaseSync): number | null {
  return (db.prepare("SELECT MIN(at) AS at FROM usage").get() as Json).at ?? null;
}
