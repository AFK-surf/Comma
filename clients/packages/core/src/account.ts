// What the core keeps for one signed-in account: its database (one per account and API audience, deleted when the
// account signs out of this device), in which what the Comma API gave is kept as it gave it (`doc`: a resource by
// name, its JSON and when it was read). Nothing of one account is used for another: a session that changes to
// another account closes this one, and what was under way for it finds it closed.
import { migrate, SqlError, transaction, type Sql } from "@comma/core-kernel";
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
  #closed = false;

  constructor(
    userId: string,
    lease: SessionLease,
    dbName: string,
    sql: Sql,
    inMemory: boolean
  ) {
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

  /** A resource as last read, and when; null when it never was. */
  doc<T>(name: string): { value: T; readAt: number } | null {
    if (this.#closed) return null;
    const row = this.#sql.all("SELECT json, read_at FROM doc WHERE name = ?", [
      name,
    ])[0];
    if (!row) return null;
    return { value: JSON.parse(row[0] as string) as T, readAt: row[1] as number };
  }

  /** Keeps a resource as read now. Does nothing once the account is closed (a read that came back too late). */
  putDoc(name: string, value: unknown, now: number): boolean {
    if (this.#closed) return false;
    this.#sql.run(
      "INSERT INTO doc (name, json, read_at) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET json = excluded.json, read_at = excluded.read_at",
      [name, JSON.stringify(value), now]
    );
    return true;
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

  /** Lets a kept resource go (bounded caches drop their oldest). */
  deleteDoc(name: string): void {
    if (this.#closed) return;
    this.#sql.run("DELETE FROM doc WHERE name = ?", [name]);
  }

  meta<T>(key: string): T | null {
    if (this.#closed) return null;
    const row = this.#sql.all("SELECT json FROM meta WHERE key = ?", [key])[0];
    return row ? (JSON.parse(row[0] as string) as T) : null;
  }

  setMeta(key: string, value: unknown): void {
    if (this.#closed) return;
    this.#sql.run(
      "INSERT INTO meta (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
      [key, JSON.stringify(value)]
    );
  }

  // ── stations (stations/index.ts) ─────────────────────────────────────

  /** A workspace's stations as last listed, in the list's order; null when it never was. */
  stationList<T>(workspace: string): T[] | null {
    if (this.#closed) return null;
    const rows = this.#sql.all(
      "SELECT json FROM station WHERE workspace = ? ORDER BY ord",
      [workspace]
    );
    if (rows.length === 0 && this.meta(listedKey(workspace)) === null) return null;
    return rows.map((row) => JSON.parse(row[0] as string) as T);
  }

  /** Keeps a workspace's stations as listed now, in place of those kept. */
  putStationList(
    workspace: string,
    rows: readonly { id: string }[],
    now: number
  ): void {
    if (this.#closed) return;
    transaction(this.#sql, () => putStations(this.#sql, workspace, rows, now));
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
    this.#sql.run(
      "UPDATE station SET json = ?, read_at = ? WHERE workspace = ? AND id = ?",
      [JSON.stringify(change(JSON.parse(row[0] as string) as T)), now, workspace, id]
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
      for (const t of tasks)
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
    });
  }

  /** Lets the credential kept for a workspace's stations go. */
  deleteStationCredential(workspace: string): void {
    if (this.#closed) return;
    this.#sql.run("DELETE FROM station_cred WHERE workspace = ?", [workspace]);
  }
}

export { SqlError };
