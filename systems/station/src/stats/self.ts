// The station's own statistics (`self`), read from what it records: its model calls (the usage table, as its usage page
// adds them up) and its chats.
import type { DatabaseSync } from "node:sqlite";
import * as read from "../read/store.ts";
import { cost } from "../read/usage.ts";
import { chatTitle } from "../read/views.ts";
import { COMMA_STATION_SURFACE } from "../store/rows.ts";
import { type SourceRows, type StatsSource, type TaskRow, type UsageRow, stateOf } from "./rows.ts";

const FAR = 9_223_372_036_854_775_807n;

export function selfRows(db: DatabaseSync, dataDir: string, from: number): SourceRows {
  const s = read.makeStore(db, dataDir);
  const usage: UsageRow[] = read.usageGroups(s, BigInt(from), FAR, 0n).map((g) => ({
    day: g.day, session: g.session, thread: g.thread, person: g.person, account: g.profile, runtime: g.runtime, model: g.model,
    calls: g.calls, input: g.input, cacheRead: g.cacheRead, cacheWrite: g.cacheWrite + g.cacheWriteLong, output: g.output, cost: cost(g),
  }));
  const sessions = new Map(read.listSessions(s).map((x) => [x.key, x]));
  const stats = read.sessionStats(s, null);
  const tasks: TaskRow[] = [];
  for (const t of read.listThreads(s, "", null, null)) {
    const members = t.sessions.filter((m) => sessions.has(m.session));
    if (members.length === 0) continue;
    const lastActiveAt = Math.max(t.thread.createdAt, t.lastMessage?.createdAt ?? 0);
    if (lastActiveAt < from) continue;
    const turns = members.flatMap((m) => stats.get(m.session)?.lastTurn ?? []);
    const latest = turns.sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0))[0] ?? null;
    tasks.push({
      thread: t.thread.id,
      surface: t.thread.surface === COMMA_STATION_SURFACE ? "page" : t.thread.surface,
      title: chatTitle(t, null),
      state: stateOf(latest),
      creator: t.thread.createdBy ?? sessions.get(members[0]!.session)?.createdBy ?? null,
      createdAt: t.thread.createdAt,
      lastActiveAt,
      archived: t.thread.hiddenAt !== null,
      agents: members.map((m) => ({ runtime: sessions.get(m.session)!.runtime, model: sessions.get(m.session)!.model })),
    });
  }
  return { usage, tasks };
}

export const selfSource = (db: DatabaseSync, dataDir: string): StatsSource => ({ id: "self", rows: async (from) => selfRows(db, dataDir, from) });
