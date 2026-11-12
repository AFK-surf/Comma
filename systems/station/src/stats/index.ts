// The station's Stats index (the stats_index table): its statistics in one structure, from every source (stats/rows.ts),
// kept as the rows the sources last gave and numbered as they change, so Salix keeps a copy as it does of the Task index
// (connector/task-index.ts carries both). A build takes each source's rows of the last days and writes what changed;
// a usage row of those days no longer given is tombstoned. Rows of days before stay as they were last given.
import { randomBytes } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { SourceRows, StatsSource } from "./rows.ts";

/// The days a build takes again: what a source can still change (a call recorded late, a chat going on).
export const BUILD_DAYS = 31;
const DAY_MS = 24 * 60 * 60_000;

/// A row as the index keeps it and the connector sends it.
/// A row's station in its key, when it names one (an outside source's other station): none for the rest, whose keys
/// stay as they were.
const at = (station: string | undefined) => (station === undefined ? [] : [`@${station}`]);

export type StatsIndexRow = { key: string; source: string; kind: string; rev: number; removed: boolean; json: string };

const SEP = "\u0000";

export class StatsIndex {
  readonly #db: DatabaseSync;
  readonly #listeners = new Set<() => void>();

  constructor(db: DatabaseSync) {
    this.#db = db;
  }

  epoch(): string {
    const had = this.#meta("stats_index_epoch");
    if (had !== null) return had;
    const epoch = randomBytes(16).toString("hex");
    this.#setMeta("stats_index_epoch", epoch);
    return epoch;
  }

  rev(): number {
    return Number(this.#meta("stats_index_rev") ?? 0);
  }

  since(since: number, limit: number): StatsIndexRow[] {
    return (this.#db.prepare("SELECT key, source, kind, rev, removed, json FROM stats_index WHERE rev > ? ORDER BY rev LIMIT ?").all(since, limit) as any[]).map((r) => ({
      key: r.key, source: r.source, kind: r.kind, rev: r.rev, removed: r.removed !== 0, json: r.json,
    }));
  }

  /// Tombstones Salix holds go.
  prune(through: number): void {
    this.#db.prepare("DELETE FROM stats_index WHERE removed = 1 AND rev <= ?").run(through);
  }

  listen(changed: () => void): () => void {
    this.#listeners.add(changed);
    return () => void this.#listeners.delete(changed);
  }

  /// `source`'s rows from the day of `from` on, written where they changed; how many rows changed.
  apply(source: string, rows: SourceRows, from: number): number {
    const fromDay = new Date(Math.floor(from / DAY_MS) * DAY_MS).toISOString().slice(0, 10);
    const given = new Map<string, { kind: string; json: string }>();
    for (const u of rows.usage ?? []) {
      if (u.day < fromDay) continue;
      given.set([source, "usage", ...at(u.station), u.day, u.session, u.person ?? "", u.account ?? "", u.runtime, u.model ?? ""].join(SEP), { kind: "usage", json: JSON.stringify(u) });
    }
    for (const t of rows.tasks ?? []) given.set([source, "task", ...at(t.station), String(t.thread)].join(SEP), { kind: "task", json: JSON.stringify(t) });
    if (rows.status !== undefined) given.set([source, "source"].join(SEP), { kind: "source", json: JSON.stringify({ source, ...rows.status }) });
    let rev = this.rev();
    let changed = 0;
    this.#db.exec("SAVEPOINT stats_index");
    try {
      const get = this.#db.prepare("SELECT json, removed FROM stats_index WHERE key = ?");
      const put = this.#db.prepare(
        "INSERT INTO stats_index (key, source, kind, rev, json, removed) VALUES (?, ?, ?, ?, ?, 0) ON CONFLICT (key) DO UPDATE SET rev = excluded.rev, json = excluded.json, removed = 0",
      );
      for (const [key, row] of given) {
        const had = get.get(key) as { json: string; removed: number } | undefined;
        if (had !== undefined && had.removed === 0 && had.json === row.json) continue;
        put.run(key, source, row.kind, ++rev, row.json);
        changed++;
      }
      // A usage row of these days no longer given (its calls were another day's after all): gone; but not one of a
      // station of the source not read this time.
      const kept = rows.usage === undefined ? [] : (this.#db.prepare("SELECT key, json FROM stats_index WHERE source = ? AND kind = 'usage' AND removed = 0").all(source) as { key: string; json: string }[]);
      const unread = new Set(rows.unread ?? []);
      const drop = this.#db.prepare("UPDATE stats_index SET removed = 1, rev = ? WHERE key = ?");
      for (const k of kept) {
        if (given.has(k.key)) continue;
        const row = JSON.parse(k.json);
        if ((row.day ?? "") < fromDay || unread.has(row.station ?? "")) continue;
        drop.run(++rev, k.key);
        changed++;
      }
      if (changed > 0) this.#setMeta("stats_index_rev", String(rev));
      this.#db.exec("RELEASE stats_index");
    } catch (e) {
      this.#db.exec("ROLLBACK TO stats_index");
      this.#db.exec("RELEASE stats_index");
      throw e;
    }
    if (changed > 0) for (const l of this.#listeners) l();
    return changed;
  }

  /// Every source's rows of the last BUILD_DAYS before `now`, each written as it changed; a source that fails or has
  /// nothing to give (no grant) keeps what it gave before.
  async build(sources: StatsSource[], now: number, failed: (source: string, error: Error) => void = () => {}): Promise<number> {
    const from = now - BUILD_DAYS * DAY_MS;
    let changed = 0;
    for (const s of sources) {
      try {
        const rows = await s.rows(from);
        if (rows !== null) changed += this.apply(s.id, rows, from);
      } catch (e) {
        failed(s.id, e as Error);
      }
    }
    return changed;
  }

  #meta(key: string): string | null {
    return (this.#db.prepare("SELECT value FROM meta WHERE key = ?").get(key) as { value: string } | undefined)?.value ?? null;
  }

  #setMeta(key: string, value: string): void {
    this.#db.prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value").run(key, value);
  }
}
