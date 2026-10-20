// A database on Node (node:sqlite): a desktop app's utility process, and tests. Each statement is prepared once and
// kept; rows come as arrays.
import { DatabaseSync, type StatementSync } from "node:sqlite";
import { type Sql, type SqlRow, type SqlValue, sqlError } from "./sql.ts";

export class NodeSql implements Sql {
  readonly db: DatabaseSync;
  readonly #statements = new Map<string, StatementSync>();
  #closed = false;
  /// Kept open by close (a test's database in memory, opened again by a core started anew).
  readonly #keep: boolean;

  constructor(db: DatabaseSync, keep = false) {
    this.db = db;
    this.#keep = keep;
  }

  /// A file, opened as the core uses it: one process at a time (locking_mode EXCLUSIVE: a second process finds it
  /// busy), a write-ahead log, a busy wait of 5 s.
  static file(path: string): NodeSql {
    const db = new DatabaseSync(path, { timeout: 5000 });
    try {
      db.exec(
        "PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"
      );
    } catch (e) {
      db.close();
      throw sqlError(e);
    }
    return new NodeSql(db);
  }

  /// A database in memory.
  static memory(keep = false): NodeSql {
    return new NodeSql(new DatabaseSync(":memory:"), keep);
  }

  #prepare(sql: string): StatementSync {
    let s = this.#statements.get(sql);
    if (!s) {
      s = this.db.prepare(sql);
      s.setReturnArrays(true);
      this.#statements.set(sql, s);
    }
    return s;
  }

  exec(sql: string): void {
    try {
      this.db.exec(sql);
    } catch (e) {
      throw sqlError(e);
    }
  }

  run(sql: string, params: readonly SqlValue[] = []): number {
    try {
      return Number(this.#prepare(sql).run(...(params as SqlValue[])).changes);
    } catch (e) {
      throw sqlError(e);
    }
  }

  all(sql: string, params: readonly SqlValue[] = []): SqlRow[] {
    try {
      return this.#prepare(sql).all(...(params as SqlValue[])) as unknown as SqlRow[];
    } catch (e) {
      throw sqlError(e);
    }
  }

  close(): void {
    if (this.#closed || this.#keep) return;
    this.#closed = true;
    this.#statements.clear();
    this.db.close();
  }
}
