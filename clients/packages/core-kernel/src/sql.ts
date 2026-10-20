// A SQLite database as the core uses it: synchronously, from the core's one thread, which is its only writer (each
// host opens it so: locking_mode EXCLUSIVE on Node, OPFS access handles in a browser). The host prepares each statement
// once and keeps it. Its schema moves forward by numbered steps (`PRAGMA user_version`), each in one transaction.

/// A value SQLite takes and gives: no BigInt (integers stay within 2^53), text, bytes, null.
export type SqlValue = null | number | string | Uint8Array;
export type SqlRow = SqlValue[];

/// One SQLite database. What fails throws a SqlError.
export interface Sql {
  /// Statements without parameters, one after another.
  exec(sql: string): void;
  /// One statement; how many rows it changed.
  run(sql: string, params?: readonly SqlValue[]): number;
  /// One statement's rows, each its columns in order.
  all(sql: string, params?: readonly SqlValue[]): SqlRow[];
  close(): void;
}

/// What SQLite said went wrong: `full` (no room left: the disk or the browser's quota), `busy` (another process holds
/// the database), or anything else.
export class SqlError extends Error {
  readonly kind: "full" | "busy" | "other";
  constructor(message: string, kind: "full" | "busy" | "other") {
    super(message);
    this.kind = kind;
  }
}

/// SQLite's error as a SqlError, by its result code or its words.
export function sqlError(e: unknown): SqlError {
  if (e instanceof SqlError) return e;
  const message = e instanceof Error ? e.message : String(e);
  const raw = e as { errcode?: unknown; resultCode?: unknown } | null;
  const code =
    typeof raw?.errcode === "number"
      ? raw.errcode
      : typeof raw?.resultCode === "number"
        ? raw.resultCode
        : null;
  const primary = code === null ? null : code & 0xff;
  if (primary === 13 || /SQLITE_FULL|database or disk is full|quota/i.test(message))
    return new SqlError(message, "full");
  if (
    primary === 5 ||
    primary === 6 ||
    /SQLITE_BUSY|SQLITE_LOCKED|database is locked/i.test(message)
  )
    return new SqlError(message, "busy");
  return new SqlError(message, "other");
}

/// Runs `body` in one transaction: all of it is kept, or (it threw) none.
export function transaction<T>(sql: Sql, body: () => T): T {
  sql.exec("BEGIN IMMEDIATE");
  try {
    const out = body();
    sql.exec("COMMIT");
    return out;
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already (SQLite ends a transaction itself on some errors).
    }
    throw e;
  }
}

/// Brings the schema to the last step: step i (from 1) runs when `user_version` is below i, each in its own transaction
/// with the version it reaches. A database written by a newer core (a version above the last step) is refused: the
/// caller starts a fresh one rather than write over what it does not know.
export function migrate(
  sql: Sql,
  steps: readonly ((sql: Sql) => void)[]
): { from: number; to: number } {
  const from = Number(sql.all("PRAGMA user_version")[0]?.[0] ?? 0);
  if (from > steps.length)
    throw new SqlError(
      `database version ${from} is newer than this core's ${steps.length}`,
      "other"
    );
  for (let v = from; v < steps.length; v++) {
    transaction(sql, () => {
      steps[v]!(sql);
      sql.exec(`PRAGMA user_version = ${v + 1}`);
    });
  }
  return { from, to: steps.length };
}
