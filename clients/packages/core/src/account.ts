// What the core keeps for one signed-in account: its database (one per account and API audience, deleted when the
// account signs out of this device), in which what the Comma API gave is kept as it gave it (`doc`: a resource by
// name, its JSON and when it was read). Nothing of one account is used for another: a session that changes to
// another account closes this one, and what was under way for it finds it closed.
import { migrate, share, SqlError, transaction, type Sql } from "@comma/core-kernel";
import type { Meter } from "@comma/core-kernel";
import type { SessionLease } from "./host.ts";

/** The schema, step by step (`PRAGMA user_version`). */
const STEPS: ((sql: Sql) => void)[] = [
  (sql) => {
    sql.exec(`
      CREATE TABLE doc (name TEXT PRIMARY KEY, json TEXT NOT NULL, read_at INTEGER NOT NULL);
      CREATE TABLE meta (key TEXT PRIMARY KEY, json TEXT NOT NULL);
    `);
  },
  // What the core keeps of the stations it reaches directly (stations/*). Each row keeps what the control plane or the
  // station gave as JSON (`json`, passed through as it came: a field added needs no migration), beside the columns it
  // is found and sorted by.
  // - `station`: a workspace's stations as its list gave them (`GET /v1/comma/workspaces/:ws/stations`), `ord` their
  //   place in it; `meta` `stations.listed:<ws>` says the list was read (an empty one is not one never read).
  // - `station_cred`: the member credential for a workspace's stations (`POST .../station-credential`: credential,
  //   issued_at, expires_at, relay_urls), issued for this device's endpoint `device`; `expires_at` in unix seconds.
  // - `station_task`: a Task a station hosts (its page chat), by (station, thread): its status, last activity and
  //   revision as the station says, `shown_at` when it was last shown here (the entries kept follow it).
  // - `station_entry`: a station Task's entries by their number `n`, the latest 500 of the 64 Tasks last shown.
  // - `station_outbox`: what this device sent a station and it has not confirmed, by the write's key `client_key`
  //   (its idempotency key); `thread` null for a new Task's first message.
  (sql) => {
    sql.exec(`
      CREATE TABLE station (workspace TEXT NOT NULL, id TEXT NOT NULL, ord INTEGER NOT NULL, json TEXT NOT NULL,
        read_at INTEGER NOT NULL, PRIMARY KEY (workspace, id));
      CREATE INDEX station_by_id ON station (id);
      CREATE TABLE station_cred (workspace TEXT PRIMARY KEY, device TEXT NOT NULL, expires_at INTEGER NOT NULL,
        json TEXT NOT NULL);
      CREATE TABLE station_task (station TEXT NOT NULL, thread TEXT NOT NULL, workspace TEXT NOT NULL, status TEXT,
        last_activity_at INTEGER, rev INTEGER, shown_at INTEGER, json TEXT NOT NULL, PRIMARY KEY (station, thread));
      CREATE INDEX station_task_recent ON station_task (workspace, last_activity_at DESC);
      CREATE INDEX station_task_shown ON station_task (shown_at DESC);
      CREATE TABLE station_entry (station TEXT NOT NULL, thread TEXT NOT NULL, n INTEGER NOT NULL, json TEXT NOT NULL,
        PRIMARY KEY (station, thread, n));
      CREATE TABLE station_outbox (client_key TEXT PRIMARY KEY, station TEXT NOT NULL, thread TEXT,
        at INTEGER NOT NULL, json TEXT NOT NULL);
      CREATE INDEX station_outbox_by_thread ON station_outbox (station, thread, at);
    `);
    // The station lists kept as documents before (`stations.list.<ws>`) become rows.
    const lists = sql.all(
      "SELECT name, json, read_at FROM doc WHERE substr(name, 1, 14) = 'stations.list.'"
    );
    for (const [name, json, readAt] of lists) {
      const workspace = String(name).slice("stations.list.".length);
      const rows: unknown = JSON.parse(String(json));
      if (!Array.isArray(rows)) continue;
      putStations(sql, workspace, rows, Number(readAt));
    }
    sql.run("DELETE FROM doc WHERE substr(name, 1, 14) = 'stations.list.'");
  },
  // The downloads index (`downloads`) an earlier core kept names files that its start removed while the account's
  // database opened: it goes, and those files download again when shown.
  (sql) => {
    sql.run("DELETE FROM doc WHERE name = 'downloads'");
  },
  // - `item`: a collection kept item by item (`putItems`): its name, each item's key and JSON. A change writes the
  //   items that changed, not the collection again; `meta` `items:<name>` says it was kept (an empty one too).
  (sql) => {
    sql.exec(`
      CREATE TABLE item (name TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (name, key));
    `);
  },
];

const listedKey = (workspace: string) => `stations.listed:${workspace}`;

/** A workspace's stations, as listed now, in place of those kept (in the caller's transaction). */
function putStations(
  sql: Sql,
  workspace: string,
  rows: readonly unknown[],
  now: number
): void {
  sql.run("DELETE FROM station WHERE workspace = ?", [workspace]);
  rows.forEach((row, ord) => {
    const id = (row as { id?: unknown } | null)?.id;
    if (typeof id !== "string") return;
    sql.run(
      "INSERT OR REPLACE INTO station (workspace, id, ord, json, read_at) VALUES (?, ?, ?, ?, ?)",
      [workspace, id, ord, JSON.stringify(row), now]
    );
  });
  sql.run(
    "INSERT INTO meta (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
    [listedKey(workspace), JSON.stringify(now)]
  );
}

/** A member credential for a workspace's stations, as the control plane issued it. */
export type KeptStationCredential<T> = {
  /** The endpoint it was issued for. */
  device: string;
  /** Unix seconds. */
  expiresAt: number;
  value: T;
};

/** Text as a part of a file name. */
function safe(text: string): string {
  return text.replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 96);
}

/** The database's name for an account: its API's host and its user id, as a file name. */
export function accountDbName(audience: string, userId: string): string {
  let host = audience;
  try {
    host = new URL(audience).host;
  } catch {
    // Not a URL: the audience as it is.
  }
  return `account-${safe(host)}-${safe(userId)}`;
}

export class Account {
  readonly userId: string;
  /** The session its requests go out for (a new generation of the same session replaces it). */
  lease: SessionLease;
  readonly dbName: string;
  /** Whether it is kept only this run (its file could not be opened). */
  readonly inMemory: boolean;
  readonly #sql: Sql;
  readonly #meter: Meter | null;
  /** With a meter: what each document was last written as, to count a write of the same bytes. */
  readonly #written = new Map<string, string>();
  /** Each document read or written this run, as `doc` gives it. */
  readonly #docs = new Map<string, { value: unknown; readAt: number }>();
  /** The same for `meta` and for each workspace's `stationList`. */
  readonly #metas = new Map<string, unknown>();
  readonly #stations = new Map<string, unknown[] | null>();
  readonly #items = new Map<string, Map<string, unknown>>();
  #closed = false;

  constructor(
    userId: string,
    lease: SessionLease,
    dbName: string,
    sql: Sql,
    inMemory: boolean,
    meter?: Meter
  ) {
    this.#meter = meter ?? null;
    this.userId = userId;
    this.lease = lease;
    this.dbName = dbName;
    this.inMemory = inMemory;
    this.#sql = sql;
    try {
      migrate(sql, STEPS);
    } catch (e) {
      sql.close();
      throw e;
    }
  }

  get closed(): boolean {
    return this.#closed;
  }

  /** Lets the database go; what is under way for this account finds it closed. */
  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#sql.close();
  }

  /**
   * A resource as last read, and when; null when it never was. The same object each time while it is unchanged (read
   * from the disk once a run), so what is made of it is kept too (core-kernel keep.ts): a reader must not change it.
   */
  doc<T>(name: string): { value: T; readAt: number } | null {
    if (this.#closed) return null;
    const held = this.#docs.get(name);
    if (held) return held as { value: T; readAt: number };
    const row = this.#sql.all("SELECT json, read_at FROM doc WHERE name = ?", [
      name,
    ])[0];
    if (!row) return null;
    const read = {
      value: this.held(JSON.parse(row[0] as string)) as T,
      readAt: row[1] as number,
    };
    this.#docs.set(name, read);
    return read;
  }

  /**
   * Keeps a resource as read now. Does nothing once the account is closed (a read that came back too late). A value
   * equal to the one held is only marked read now.
   */
  putDoc(name: string, given: unknown, now: number): boolean {
    if (this.#closed) return false;
    const held = this.#docs.get(name);
    // What did not change keeps the objects held (core-kernel keep.ts): readers' parts made of them are kept, and a
    // document that did not change at all is not written again.
    const value = share(held?.value, given);
    if (held && held.value === value) {
      held.readAt = now;
      this.#sql.run("UPDATE doc SET read_at = ? WHERE name = ?", [now, name]);
      return true;
    }
    const json = JSON.stringify(value);
    this.#wrote(`doc:${name}`, json);
    this.#sql.run(
      "INSERT INTO doc (name, json, read_at) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET json = excluded.json, read_at = excluded.read_at",
      [name, json, now]
    );
    this.#docs.set(name, { value: this.held(value), readAt: now });
    return true;
  }

  /**
   * A value held for readers to share (a document, a GET's answer); frozen with a meter (a test's core), so a reader
   * that changes it fails.
   */
  held<T>(value: T): T {
    return this.#meter ? deepFreeze(value) : value;
  }

  /** Counts a write for the meter: by the kind of what was written (a document's name up to its first `.`/`:`). */
  #wrote(key: string, json: string): void {
    if (!this.#meter) return;
    const same = this.#written.get(key) === json;
    this.#written.set(key, json);
    this.#meter.wrote(key.split(/[.:]/, 2).join(":"), json.length, same);
  }

  /** Changes a resource kept already (an answer that carries part of it); false when there is none. */
  updateDoc<T>(name: string, change: (value: T) => T, now: number): boolean {
    if (this.#closed) return false;
    return transaction(this.#sql, () => {
      const was = this.doc<T>(name);
      if (!was) return false;
      this.putDoc(name, change(was.value), now);
      return true;
    });
  }

  /**
   * A collection as kept item by item, in no order of its own (its items say theirs); null when it never was. The same
   * objects each time while they are unchanged, as `doc` gives its documents.
   */
  items<T>(name: string): T[] | null {
    const held = this.#heldItems(name);
    return held ? ([...held.values()] as T[]) : null;
  }

  /**
   * Keeps a collection as it is now, by each item's `key`: only the items that changed are written (an item equal to
   * the one kept keeps that one's object), and those gone are deleted.
   */
  putItems<T>(name: string, items: readonly T[], key: (item: T) => string): void {
    if (this.#closed) return;
    const held = this.#heldItems(name) ?? new Map<string, unknown>();
    const next = new Map<string, unknown>();
    transaction(this.#sql, () => {
      for (const item of items) {
        const k = key(item);
        const was = held.get(k);
        const kept = share(was, item);
        next.set(k, kept === was ? was : this.held(kept));
        if (kept === was) continue;
        const json = JSON.stringify(kept);
        this.#wrote(`item:${name}/${k}`, json);
        this.#sql.run(
          "INSERT OR REPLACE INTO item (name, key, json) VALUES (?, ?, ?)",
          [name, k, json]
        );
      }
      for (const k of held.keys())
        if (!next.has(k))
          this.#sql.run("DELETE FROM item WHERE name = ? AND key = ?", [name, k]);
      if (!this.#items.has(name)) this.setMeta(`items:${name}`, true);
    });
    this.#items.set(name, next);
  }

  /** Lets a collection go. */
  deleteItems(name: string): void {
    if (this.#closed) return;
    this.#items.delete(name);
    this.#sql.run("DELETE FROM item WHERE name = ?", [name]);
    this.#sql.run("DELETE FROM meta WHERE key = ?", [`items:${name}`]);
    this.#metas.delete(`items:${name}`);
  }

  #heldItems(name: string): Map<string, unknown> | null {
    if (this.#closed) return null;
    const held = this.#items.get(name);
    if (held) return held;
    if (this.meta<boolean>(`items:${name}`) !== true) return null;
    const rows = this.#sql.all(
      "SELECT key, json FROM item WHERE name = ? ORDER BY key",
      [name]
    );
    const read = new Map(
      rows.map((row) => [String(row[0]), this.held(JSON.parse(row[1] as string))])
    );
    this.#items.set(name, read);
    return read;
  }

  /** Lets a kept resource go (bounded caches drop their oldest). */
  deleteDoc(name: string): void {
    if (this.#closed) return;
    this.#docs.delete(name);
    this.#sql.run("DELETE FROM doc WHERE name = ?", [name]);
  }

  meta<T>(key: string): T | null {
    if (this.#closed) return null;
    if (this.#metas.has(key)) return this.#metas.get(key) as T | null;
    const row = this.#sql.all("SELECT json FROM meta WHERE key = ?", [key])[0];
    const value = row ? this.held(JSON.parse(row[0] as string) as T) : null;
    this.#metas.set(key, value);
    return value;
  }

  /** Keeps `value` under `key`; a value equal to the one held is not written again. */
  setMeta(key: string, value: unknown): void {
    if (this.#closed) return;
    const held = this.meta(key);
    if (held !== null && share(held, value) === held) return;
    const json = JSON.stringify(value);
    this.#wrote(`meta:${key}`, json);
    this.#sql.run(
      "INSERT INTO meta (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
      [key, json]
    );
    this.#metas.set(key, this.held(value));
  }

  // ── stations (stations/index.ts) ─────────────────────────────────────

  /** A workspace's stations as last listed, in the list's order; null when it never was. */
  stationList<T>(workspace: string): T[] | null {
    if (this.#closed) return null;
    if (this.#stations.has(workspace))
      return this.#stations.get(workspace) as T[] | null;
    const rows = this.#sql.all(
      "SELECT json FROM station WHERE workspace = ? ORDER BY ord",
      [workspace]
    );
    const list =
      rows.length === 0 && this.meta(listedKey(workspace)) === null
        ? null
        : this.held(rows.map((row) => JSON.parse(row[0] as string) as T));
    this.#stations.set(workspace, list);
    return list;
  }

  /**
   * Keeps a workspace's stations as listed now, in place of those kept: only the rows that changed or moved are
   * written, and those no longer listed removed.
   */
  putStationList(
    workspace: string,
    rows: readonly { id: string }[],
    now: number
  ): void {
    if (this.#closed) return;
    const listed = rows.filter(
      (row) => typeof (row as { id?: unknown }).id === "string"
    );
    const held = this.stationList<{ id: string }>(workspace);
    const was = new Map((held ?? []).map((row, ord) => [row.id, { row, ord }]));
    const ids = new Set(listed.map((row) => row.id));
    const kept = listed.map((row) => {
      const before = was.get(row.id);
      return before ? share(before.row, row) : row;
    });
    transaction(this.#sql, () => {
      for (const id of was.keys())
        if (!ids.has(id))
          this.#sql.run("DELETE FROM station WHERE workspace = ? AND id = ?", [
            workspace,
            id,
          ]);
      kept.forEach((row, ord) => {
        const before = was.get(row.id);
        if (before && before.row === row && before.ord === ord) return;
        const json = JSON.stringify(row);
        this.#wrote(`station:${workspace}/${row.id}`, json);
        this.#sql.run(
          "INSERT OR REPLACE INTO station (workspace, id, ord, json, read_at) VALUES (?, ?, ?, ?, ?)",
          [workspace, row.id, ord, json, now]
        );
      });
      if (held === null)
        this.#sql.run(
          "INSERT INTO meta (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
          [listedKey(workspace), JSON.stringify(now)]
        );
    });
    if (
      held !== null &&
      kept.length === held.length &&
      kept.every((row, i) => row === held[i])
    )
      return;
    this.#stations.set(workspace, this.held(kept));
    if (held === null) this.#metas.set(listedKey(workspace), this.held(now));
  }

  /** Changes one kept station's row (renamed, its presence moved); nothing when it is not kept. */
  updateStation<T>(
    workspace: string,
    id: string,
    change: (row: T) => T,
    now: number
  ): void {
    if (this.#closed) return;
    const row = this.#sql.all(
      "SELECT json FROM station WHERE workspace = ? AND id = ?",
      [workspace, id]
    )[0];
    if (!row) return;
    const changed = change(JSON.parse(row[0] as string) as T);
    this.#sql.run(
      "UPDATE station SET json = ?, read_at = ? WHERE workspace = ? AND id = ?",
      [JSON.stringify(changed), now, workspace, id]
    );
    const list = this.#stations.get(workspace);
    if (list)
      this.#stations.set(
        workspace,
        this.held(list.map((s) => ((s as { id?: unknown }).id === id ? changed : s)))
      );
  }

  /** The workspace a kept station is listed in; null when none lists it. */
  stationWorkspace(id: string): string | null {
    if (this.#closed) return null;
    const row = this.#sql.all("SELECT workspace FROM station WHERE id = ? LIMIT 1", [
      id,
    ])[0];
    return row ? (row[0] as string) : null;
  }

  /** The member credential kept for a workspace's stations; null when there is none. */
  stationCredential<T>(workspace: string): KeptStationCredential<T> | null {
    if (this.#closed) return null;
    const row = this.#sql.all(
      "SELECT device, expires_at, json FROM station_cred WHERE workspace = ?",
      [workspace]
    )[0];
    if (!row) return null;
    return {
      device: row[0] as string,
      expiresAt: row[1] as number,
      value: JSON.parse(row[2] as string) as T,
    };
  }

  /** Keeps a member credential for a workspace's stations, in place of the one kept. */
  putStationCredential(workspace: string, kept: KeptStationCredential<unknown>): void {
    if (this.#closed) return;
    this.#sql.run(
      "INSERT INTO station_cred (workspace, device, expires_at, json) VALUES (?, ?, ?, ?) ON CONFLICT(workspace) DO UPDATE SET device = excluded.device, expires_at = excluded.expires_at, json = excluded.json",
      [workspace, kept.device, kept.expiresAt, JSON.stringify(kept.value)]
    );
  }

  /** The Tasks a workspace's stations host, as last read, the latest activity first (at most `limit`). */
  stationTasks<T>(workspace: string, limit = 500): T[] {
    if (this.#closed) return [];
    return this.#sql
      .all(
        "SELECT json FROM station_task WHERE workspace = ? ORDER BY last_activity_at DESC, station, thread LIMIT ?",
        [workspace, limit]
      )
      .map((row) => JSON.parse(row[0] as string) as T);
  }

  /** Changes fields of one station-hosted Task as kept (its value), until the next read gives it again. */
  patchStationTask(
    station: string,
    thread: string,
    fields: Record<string, unknown>
  ): void {
    if (this.#closed) return;
    const row = this.#sql.all(
      "SELECT json FROM station_task WHERE station = ? AND thread = ?",
      [station, thread]
    )[0];
    if (!row) return;
    const value = { ...(JSON.parse(row[0] as string) as object), ...fields };
    this.#sql.run("UPDATE station_task SET json = ? WHERE station = ? AND thread = ?", [
      JSON.stringify(value),
      station,
      thread,
    ]);
  }

  /**
   * Keeps a workspace's station-hosted Tasks as a read gave them all, in place of those kept: a Task the read does not
   * name is gone. When each was last shown here stays.
   */
  replaceStationTasks(
    workspace: string,
    tasks: {
      station: string;
      thread: string;
      status: string | null;
      lastActivityAt: number | null;
      rev: number | null;
      value: unknown;
    }[]
  ): void {
    if (this.#closed) return;
    transaction(this.#sql, () => {
      const keep = new Set(tasks.map((t) => `${t.station}\u0000${t.thread}`));
      for (const row of this.#sql.all(
        "SELECT station, thread FROM station_task WHERE workspace = ?",
        [workspace]
      )) {
        const [station, thread] = [String(row[0]), String(row[1])];
        if (!keep.has(`${station}\u0000${thread}`))
          this.#sql.run("DELETE FROM station_task WHERE station = ? AND thread = ?", [
            station,
            thread,
          ]);
      }
      for (const t of tasks) {
        this.#wrote(`station_task:${t.station}/${t.thread}`, JSON.stringify(t.value));
        this.#sql.run(
          "INSERT INTO station_task (station, thread, workspace, status, last_activity_at, rev, json) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(station, thread) DO UPDATE SET workspace = excluded.workspace, status = excluded.status, last_activity_at = excluded.last_activity_at, rev = excluded.rev, json = excluded.json",
          [
            t.station,
            t.thread,
            workspace,
            t.status,
            t.lastActivityAt,
            t.rev,
            JSON.stringify(t.value),
          ]
        );
      }
    });
  }

  /** Lets the credential kept for a workspace's stations go. */
  deleteStationCredential(workspace: string): void {
    if (this.#closed) return;
    this.#sql.run("DELETE FROM station_cred WHERE workspace = ?", [workspace]);
  }
}

export { SqlError };

function deepFreeze<T>(value: T): T {
  if (typeof value === "object" && value !== null && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const v of Object.values(value)) deepFreeze(v);
  }
  return value;
}
