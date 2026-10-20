// The write side over a COPY of a real station's data (the Rust station's ~/.stillfail, or $STILLFAIL_COMPAT_DATA): it
// opens as it is (version 12, nothing added), reads as read/store.ts reads it, and a write cycle leaves the database as
// the Rust schema has it, with archive files byte for byte as the Rust wrote them. Skipped where there is no station.
// The live database is never opened: the copy is made with cp (db, -wal, -shm, archive/threads) and removed after.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import * as read from "../src/read/store.ts";
import { SCHEMA } from "../src/store/schema.ts";
import { MANUAL, Store, newMessage, turnSummaryJson } from "../src/store/store.ts";

const live = process.env.STILLFAIL_COMPAT_DATA ?? join(homedir(), ".stillfail");
const present = existsSync(join(live, "stillfail.db"));
const dir = present ? mkdtempSync(join(tmpdir(), "store-compat-")) : "";
after(() => {
  if (dir) rmSync(dir, { recursive: true, force: true });
});

/// Every table's columns, and every index's and view's SQL: what the schema is.
function shape(path: string): string[] {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const out: string[] = [];
    for (const m of db.prepare("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").all() as any[]) {
      out.push(`${m.type} ${m.name}: ${m.sql}`);
      if (m.type === "table") {
        for (const c of db.prepare(`SELECT name, type, "notnull", dflt_value, pk FROM pragma_table_info('${m.name}')`).all() as any[]) {
          out.push(`  ${m.name}.${c.name} ${c.type} ${c.notnull} ${c.dflt_value} ${c.pk}`);
        }
      }
    }
    out.push(`user_version ${(db.prepare("PRAGMA user_version").get() as any).user_version}`);
    return out;
  } finally {
    db.close();
  }
}

const noToken = <T extends { token: string }>(r: T) => {
  const { token: _, ...rest } = r;
  return rest;
};

test("a copy of a real station's data opens, reads the same, and takes a write cycle", { skip: !present && "no station data here" }, (t) => {
  for (const suffix of ["", "-wal", "-shm"]) {
    if (existsSync(join(live, `stillfail.db${suffix}`))) cpSync(join(live, `stillfail.db${suffix}`), join(dir, `stillfail.db${suffix}`));
  }
  if (existsSync(join(live, "archive", "threads"))) cpSync(join(live, "archive", "threads"), join(dir, "archive", "threads"), { recursive: true });
  const path = join(dir, "stillfail.db");
  const before = shape(path);

  const store = Store.open(path);
  let opened: string[] = [];
  try {
    assert.equal(store.archiveDir(), join(dir, "archive"));
    // Opening adds nothing to what the Rust station keeps, beyond the tables and indexes of the Rust SCHEMA a station
    // older than that source had not made yet (CREATE … IF NOT EXISTS, as the Rust's open makes them).
    opened = shape(path);
    assert.deepEqual(before.filter((l) => !opened.includes(l)), [], "nothing changed or gone");
    const added = opened.filter((l) => !before.includes(l));
    for (const line of added) {
      const name = /^(?:table|index) (\w+):/.exec(line)?.[1] ?? /^  (\w+)\./.exec(line)?.[1];
      assert.ok(name && new RegExp(`CREATE (TABLE|INDEX) IF NOT EXISTS ${name} `).test(SCHEMA), `only the Rust SCHEMA's own: ${line.split("\n")[0]}`);
      assert.ok(!before.some((l) => l.startsWith(`table ${name}:`)), "no column added to a table the station had");
    }

    // Reads: the same as read/store.ts over the same file.
    const r = read.makeStore(new DatabaseSync(path, { readOnly: true }), dir);
    try {
      const viewer: string = (store.db.prepare("SELECT viewer FROM reads GROUP BY viewer ORDER BY COUNT(*) DESC LIMIT 1").get() as any)?.viewer ?? "local";
      assert.deepEqual(store.listSessions().map(noToken), read.listSessions(r));
      assert.deepEqual(store.listThreads(viewer, null, null), read.listThreads(r, viewer, null, null));
      assert.deepEqual(store.participants(null), read.participants(r, null));
      assert.deepEqual(store.listBindings(), read.listBindings(r));
      assert.deepEqual(store.listJobs(null).map(noToken), read.listJobs(r, null));
      assert.deepEqual(store.answersSince(0), read.answersSince(r, 0));
      const stats = store.sessionStats(null);
      for (const [key, s] of read.sessionStats(r, null)) {
        const mine = stats.get(key)!;
        assert.deepEqual({ ...mine, lastTurn: mine.lastTurn && turnSummaryJson(mine.lastTurn) }, s, key);
      }
      for (const s of store.listSessions().slice(0, 30)) {
        assert.deepEqual(store.listTurns(s.key).map((t) => ({ ...turnSummaryJson(t.summary), id: t.id })), read.listTurns(r, s.key));
      }
      for (const t of store.db.prepare("SELECT id FROM threads ORDER BY id DESC LIMIT 60").all() as any[]) {
        assert.deepEqual(store.entriesBefore(t.id, null, 50), read.entriesBefore(r, t.id, null, 50));
        assert.deepEqual(store.messagesBefore(t.id, null, 50), read.messagesBefore(r, t.id, null, 50));
        assert.deepEqual(store.lastMessage(t.id), read.lastMessage(r, t.id));
        assert.deepEqual(store.pendingCard(t.id), read.pendingCard(r, t.id));
      }
    } finally {
      r.db.close();
    }

    // A message into a thread with a session in lists: appended as the next entry, delivered once.
    const live = store.db
      .prepare(
        `SELECT ts.thread, ts.session FROM thread_sessions ts JOIN threads t ON t.id = ts.thread JOIN sessions s ON s.key = ts.session
         WHERE t.archived_at IS NULL AND t.hidden_at IS NULL AND s.archived_at IS NULL ORDER BY t.id DESC LIMIT 1`,
      )
      .get() as any ??
      // A station whose chats are all in the archive: any thread with a session (writing brings it back).
      (store.db.prepare(`SELECT thread, session FROM thread_sessions ORDER BY thread DESC LIMIT 1`).get() as any);
    if (!live) {
      // A station with no chat yet (a new one): nothing to write a message into.
      t.diagnostic("no thread with a session in this station's data: the write cycle is not run");
      return;
    }
    {
      const last = store.lastEntry(live.thread);
      const [n, fresh] = store.insertMessage(newMessage(live.thread, "compat.1", "person", "local", "compat test"));
      assert.deepEqual([n, fresh], [last + 1, true]);
      assert.deepEqual(store.insertMessage(newMessage(live.thread, "compat.1", "person", "local", "again")), [n, false]);
      assert.deepEqual(store.deliver(live.thread, n, [live.session]), [live.session]);
      assert.deepEqual(store.deliver(live.thread, n, [live.session]), []);
      assert.ok(store.pendingMessages(live.session).some((p) => p.message.n === n && p.message.thread === live.thread));
      store.markDelivered(live.session, [[live.thread, n]]);
      store.startTurnFor("compat-turn", live.session, "input", { profile: null, person: "local", thread: live.thread });
      store.endTurn("compat-turn", "completed", null, "all_done", null);
      assert.equal(store.lastTurn(live.session)!.ending, "all_done");
    }

    // An archived session's threads, written by the Rust station: brought back, then written out again byte for byte.
    const archived = store.db
      .prepare(
        `SELECT s.key FROM sessions s WHERE s.archived_at IS NOT NULL AND EXISTS (SELECT 1 FROM thread_sessions ts JOIN threads t ON t.id = ts.thread
           WHERE ts.session = s.key AND t.archived_at IS NOT NULL) ORDER BY s.archived_at DESC LIMIT 3`,
      )
      .all() as any[];
    if (archived.length === 0) t.diagnostic("no archived session with archived threads: the byte-for-byte check did not run");
    for (const { key } of archived) {
      const files = new Map<number, Buffer>();
      for (const t of store.sessionThreads(key)) {
        const file = join(dir, "archive", "threads", `${t.thread.id}.jsonl.zst`);
        if (existsSync(file)) files.set(t.thread.id, zstdDecompressSync(readFileSync(file)));
      }
      const entries = new Map([...files.keys()].map((id) => [id, store.entriesAfter(id, 0)]));
      const by = store.getSession(key)!.archivedBy ?? MANUAL;
      store.setArchived(key, false, MANUAL);
      for (const id of files.keys()) {
        if (store.getThread(id)!.hiddenAt !== null) continue;
        assert.ok(!existsSync(join(dir, "archive", "threads", `${id}.jsonl.zst`)), "brought back into the database");
        assert.deepEqual(store.entriesAfter(id, 0), entries.get(id));
      }
      store.setArchived(key, true, by);
      for (const [id, text] of files) {
        const file = join(dir, "archive", "threads", `${id}.jsonl.zst`);
        assert.ok(existsSync(file));
        assert.ok(zstdDecompressSync(readFileSync(file)).equals(text), `thread ${id} written out as the Rust wrote it`);
      }
    }

    // A chat hidden by hand and shown again: out to its file and back.
    const chat = store.db
      .prepare("SELECT id FROM threads t WHERE hidden_at IS NULL AND archived_at IS NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread = t.id) ORDER BY id DESC LIMIT 1")
      .get() as any;
    assert.ok(chat, "a thread to hide");
    {
      const entries = store.entriesAfter(chat.id, 0);
      store.setThreadHidden(chat.id, true, MANUAL);
      assert.ok(existsSync(join(dir, "archive", "threads", `${chat.id}.jsonl.zst`)));
      assert.deepEqual(store.entriesAfter(chat.id, 0), entries);
      store.setThreadHidden(chat.id, false, MANUAL);
      assert.deepEqual(store.entriesAfter(chat.id, 0), entries);
    }
  } finally {
    store.close();
  }

  // The database is as the Rust schema has it: nothing new since it was opened, and whole.
  assert.deepEqual(shape(path), opened);
  const db = new DatabaseSync(path, { readOnly: true });
  assert.equal((db.prepare("PRAGMA integrity_check").get() as any).integrity_check, "ok");
  db.close();
  // The sqlite3 shell, where there is one, reads it too.
  try {
    execFileSync("sqlite3", [path, "SELECT COUNT(*) FROM merged"], { stdio: "pipe" });
  } catch (e: any) {
    if (e.code !== "ENOENT") throw e;
  }
});
