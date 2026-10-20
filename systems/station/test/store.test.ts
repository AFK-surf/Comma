// the Rust station's store/tests.rs ported (same names, same checks), and what else the write side promises: cards closed
// and withdrawn, turns, jobs, bindings and usage.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import {
  AUTO, type AuthorKind, type EntryRow, type JobRow, MANUAL, type NewMessage, SCHEMA_VERSION, Store, type StoreChange, newMessage,
} from "../src/store/store.ts";
import { MERGED, SCHEMA } from "../src/store/schema.ts";

const dirs: string[] = [];
const stores: Store[] = [];
after(() => {
  for (const s of stores) {
    try {
      s.close();
    } catch {}
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "store-test-"));
  dirs.push(d);
  return d;
}

function open(path: string, archive: string | null = null): Store {
  const s = Store.open(path, archive);
  stores.push(s);
  return s;
}

const memory = () => open(":memory:");

function session(store: Store, key: string) {
  store.insertSession({ key, connect: "ds", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: 1, lastActiveAt: 1 });
}

const say = (store: Store, thread: number, ts: string, kind: AuthorKind, author: string, text: string) =>
  store.insertMessage(newMessage(thread, ts, kind, author, text));

function heard(store: Store): { changes: StoreChange[]; stop: () => void } {
  const changes: StoreChange[] = [];
  return { changes, stop: store.subscribe((c) => changes.push(c)) };
}

const archiveFile = (store: Store, thread: number) => join(store.archiveDir(), "threads", `${thread}.jsonl.zst`);

test("a database of another schema version is refused", () => {
  const path = join(tempdir(), "ember.db");
  const db = new DatabaseSync(path);
  db.exec("CREATE TABLE sessions (key TEXT); PRAGMA user_version = 8;");
  db.close();
  assert.throws(() => Store.open(path), /schema version 8; this station uses 12/);
});

test("a new database is made at version 12", () => {
  const path = join(tempdir(), "new.db");
  open(path).close();
  const db = new DatabaseSync(path, { readOnly: true });
  assert.equal((db.prepare("PRAGMA user_version").get() as any).user_version, SCHEMA_VERSION);
  assert.equal((db.prepare("PRAGMA journal_mode").get() as any).journal_mode, "wal");
  db.close();
});

test("a message is recorded once and delivered to every session in its thread", () => {
  const store = memory();
  session(store, "a");
  session(store, "b");
  const thread = store.openThread("slack:T1", "C1", "1.1", null, null);
  assert.equal(store.openThread("slack:T1", "C1", "1.1", null, null).id, thread.id);
  store.joinThread(thread.id, "a", "ds");
  assert.equal(store.joinThread(thread.id, "a", "ds"), false);
  store.joinThread(thread.id, "b", "gpt");
  const first = say(store, thread.id, "1.1", "person", "U1", "hi");
  assert.deepEqual(first, [1, true]);
  assert.deepEqual(say(store, thread.id, "1.1", "person", "U1", "hi"), [1, false]);
  assert.deepEqual(store.deliver(thread.id, first[0], ["a", "b"]), ["a", "b"]);
  assert.deepEqual(store.deliver(thread.id, first[0], ["a", "b"]), []);
  assert.deepEqual(store.pendingMessages("b").map((m) => [m.message.text, m.connect]), [["hi", "gpt"]]);
  store.markDelivered("a", [[thread.id, first[0]]]);
  assert.deepEqual(store.sessionsWithPending(), ["b"]);
  assert.equal(store.latestThread("a")!.thread.id, thread.id);
  assert.equal(store.sessionThread("b", "C1", "1.1")!.connect, "gpt");
  assert.equal(store.sessionThread("b", "C9", "1.1"), null);
});

const plain = (entries: EntryRow[]) => entries.map((e) => [e.n, e.kind, e.target !== null ? String(e.target) : (e.ts ?? ""), e.text ?? ""]);

test("a thread is a log, edits are entries of their own", () => {
  const store = memory();
  const thread = store.openThread("slack:T1", "C1", "1.1", null, null);
  const other = store.openThread("slack:T1", "C1", "2.1", null, null);
  for (const ts of ["1.1", "1.2", "1.3"]) say(store, thread.id, ts, "person", "U1", ts);
  say(store, other.id, "2.1", "person", "U1", "elsewhere");
  assert.equal(store.lastEntry(thread.id), 3);
  assert.deepEqual(store.entriesAfter(thread.id, 3), []);
  assert.equal(store.editMessage("slack:T1", "C1", "1.1", "1.1", "1.1 edited"), thread.id);
  assert.equal(store.editMessage("slack:T1", "C1", "1.1", "1.1", "1.1 edited"), null, "the same words are no change");
  assert.equal(store.editMessage("slack:T1", "C1", "1.1", "1.2", "1.2 edited"), thread.id);
  assert.equal(store.editMessage("slack:T1", "C1", "1.1", "9.9", "never seen"), null);
  store.insertMessage({ ...newMessage(thread.id, "1.4", "agent", "a", "new"), declared: "final" });
  assert.deepEqual(plain(store.entriesAfter(thread.id, 3)), [[4, "edit", "1", "1.1 edited"], [5, "edit", "2", "1.2 edited"], [6, "message", "1.4", "new"]]);
  // What was read stays true: the message entries are as they were said.
  assert.deepEqual(plain(store.entriesBetween(thread.id, 1, 2)), [[1, "message", "1.1", "1.1"], [2, "message", "1.2", "1.2"]]);
  assert.deepEqual(store.entriesBetween(thread.id, 5, 9).map((e) => e.n), [5, 6]);
  assert.deepEqual(store.entriesBefore(thread.id, 4, 2).map((e) => e.n), [2, 3]);
  assert.deepEqual(store.entriesBefore(thread.id, null, 2).map((e) => e.n), [5, 6]);
  assert.deepEqual(store.entriesAfter(other.id, 0).map((e) => e.n), [1], "each thread counts from 1");
  // Merged: the latest edit's words.
  const merged = store.messagesBefore(thread.id, null, 10).map((m) => [m.n, m.text, m.editedAt !== null]);
  assert.deepEqual(merged, [[1, "1.1 edited", true], [2, "1.2 edited", true], [3, "1.3", false], [6, "new", false]]);
  assert.deepEqual(store.messagesBefore(thread.id, 3, 1).map((m) => m.ts), ["1.2"]);
  assert.equal(store.lastMessage(thread.id)!.declared, "final");
});

test("a message still pending reaches the agent as it reads at delivery", () => {
  const store = memory();
  session(store, "a");
  const thread = store.openThread("slack:T1", "C1", "1.1", null, null);
  store.joinThread(thread.id, "a", "ds");
  for (const ts of ["1.1", "1.2"]) {
    const [n] = say(store, thread.id, ts, "person", "U1", ts);
    store.deliver(thread.id, n, ["a"]);
  }
  store.editMessage("slack:T1", "C1", "1.1", "1.1", "edited");
  assert.deepEqual(store.pendingMessages("a").map((m) => [m.message.n, m.message.text]), [[1, "edited"], [2, "1.2"]]);
  assert.equal(store.sessionStats("a").get("a")!.firstText, "edited");
});

test("reads move forward only and unread counts skip the viewer's own", () => {
  const store = memory();
  session(store, "a");
  const thread = store.openThread("slack:T1", "C1", "1.1", null, null);
  store.joinThread(thread.id, "a", "ds");
  const [mine] = say(store, thread.id, "1.2", "person", "me@x", "q");
  say(store, thread.id, "1.3", "agent", "a", "answer");
  say(store, thread.id, "1.4", "person", "you@x", "also");
  store.editMessage("slack:T1", "C1", "1.1", "1.3", "answer, edited");
  const view = (viewer: string) => store.listThreads(viewer, "a", null)[0]!;
  const me = view("me@x");
  assert.deepEqual([me.unread, me.read, me.last], [2, 0, 4]);
  assert.equal(store.unreadCount("me@x", thread.id), 2, "an edit is no message of its own");
  assert.equal(view("you@x").unread, 2);
  assert.equal(store.setRead("me@x", thread.id, mine + 1), mine + 1);
  assert.equal(store.setRead("me@x", thread.id, mine), mine + 1, "never back");
  const me2 = view("me@x");
  assert.deepEqual([me2.unread, me2.read], [1, mine + 1]);
  assert.equal(view("you@x").unread, 2, "each viewer reads for themselves");
  assert.deepEqual([view("me@x").lastMessage!.ts, view("you@x").lastMessage!.text], ["1.4", "also"]);
  // Its people, and the first thing one of them said.
  assert.deepEqual([view("me@x").people, view("me@x").firstText], [["slack:ds:me@x", "slack:ds:you@x"], "q"]);
  const slack = store.openThread("slack:T1", "C1", "2.1", null, null);
  store.joinThread(slack.id, "a", "ds");
  say(store, slack.id, "2.1", "agent", "a", "hello");
  say(store, slack.id, "2.2", "person", "U2", "<@UBOT> 看看");
  say(store, slack.id, "2.3", "person", "U1", "嗯");
  say(store, slack.id, "2.4", "person", "U2", "再看");
  const slackView = store.listThreads("me@x", null, slack.id)[0]!;
  assert.deepEqual([slackView.people, slackView.firstText], [["slack:ds:U2", "slack:ds:U1"], "<@UBOT> 看看"]);
  assert.deepEqual(store.listThreads("me@x", null, null).map((t) => t.thread.id), [slack.id, thread.id], "the latest said first");
});

test("archiving writes a thread out to a zstd file and back", () => {
  const archive = tempdir();
  const store = open(":memory:", archive);
  session(store, "a");
  session(store, "b");
  const shared = store.openThread("slack:T1", "C1", "1.1", null, null);
  const own = store.openThread("ember", "EMBER", "2.1", null, null);
  store.joinThread(shared.id, "a", "ds");
  store.joinThread(shared.id, "b", "ds");
  store.joinThread(own.id, "a", "ember");
  const at = (m: NewMessage, at: number): NewMessage => ({ ...m, at });
  store.insertMessage(at(newMessage(own.id, "2.2", "person", "local", "看看"), 1));
  store.insertMessage(at(newMessage(own.id, "2.3", "agent", "a", "好"), 2));
  store.insertMessage(at(newMessage(shared.id, "1.1", "person", "U1", "hi"), 3));
  const before = store.listThreads("local", null, own.id)[0];
  const entries = store.entriesAfter(own.id, 0);
  const file = join(archive, "threads", `${own.id}.jsonl.zst`);

  store.setArchived("a", true, MANUAL);
  assert.ok(existsSync(file), "every session of it is archived");
  assert.ok(!existsSync(join(archive, "threads", `${shared.id}.jsonl.zst`)), "b still takes part");
  const text = zstdDecompressSync(readFileSync(file)).toString("utf8");
  // The shape the Rust station writes (serde's EntryRow): its archives read here, and back.
  assert.ok(text.split("\n")[0]!.startsWith(`{"thread":${own.id},"n":1,"kind":"message","target":null,"ts":"2.2","authorKind":"person"`), text);
  assert.ok(text.split("\n")[1]!.startsWith(`{"agentIdentity":{"model":null,"effort":null},"thread":${own.id},"n":2,`), text);
  // Out of the database, read from the file the same way.
  assert.equal((store.db.prepare("SELECT COUNT(*) AS c FROM entries WHERE thread = ?").get(own.id) as any).c, 0);
  assert.deepEqual(store.entriesAfter(own.id, 0), entries);
  assert.deepEqual(store.entriesBefore(own.id, null, 1), entries.slice(1));
  assert.deepEqual(store.entriesBetween(own.id, 2, 2), entries.slice(1));
  assert.deepEqual(store.listThreads("local", null, own.id)[0], before);
  assert.deepEqual(store.participants("a").get("a"), ["local", "slack:ds:U1"]);

  store.setArchived("a", false, MANUAL);
  assert.ok(!existsSync(file), "shown again: back in the database");
  assert.deepEqual(store.entriesAfter(own.id, 0), entries);

  // Someone writing in an archived thread brings it back first.
  store.setArchived("a", true, MANUAL);
  const h = heard(store);
  assert.deepEqual(say(store, own.id, "2.4", "person", "local", "还在吗"), [3, true]);
  assert.ok(!existsSync(file));
  assert.deepEqual(store.entriesAfter(own.id, 0).map((e) => e.n), [1, 2, 3]);
  const appended = h.changes.flatMap((c) => (c.type === "thread" && c.entries.length > 0 ? [c.entries.map((e) => e.n)] : []));
  assert.deepEqual(appended, [[3]]);
  h.stop();

  // Deleting the session removes an archived thread's file with it.
  store.setArchived("a", true, MANUAL);
  store.setArchived("b", true, MANUAL);
  assert.ok(existsSync(join(archive, "threads", `${shared.id}.jsonl.zst`)));
  const removed = heard(store);
  store.deleteSession("a");
  assert.deepEqual(removed.changes.flatMap((c) => (c.type === "threadRemoved" ? [c.id] : [])), [own.id]);
  assert.ok(!existsSync(file));
  assert.deepEqual(store.entriesAfter(shared.id, 0).map((e) => e.text), ["hi"], "b's archived thread stays");
});

test("thread ids are never used again", () => {
  const store = memory();
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  store.deleteSession("a");
  assert.ok(store.openThread("ember", "EMBER", "2.1", null, null).id > thread.id);
});

test("deleting removes the session's rows and the threads only it was in", () => {
  const store = memory();
  session(store, "a");
  session(store, "b");
  const shared = store.openThread("slack:T1", "C1", "1.1", null, null);
  const own = store.openThread("ember", "EMBER", "2.1", null, null);
  store.joinThread(shared.id, "a", "ds");
  store.joinThread(shared.id, "b", "ds");
  store.joinThread(own.id, "a", "ember");
  const [said] = say(store, shared.id, "1.1", "person", "U1", "hi");
  store.deliver(shared.id, said, ["a", "b"]);
  say(store, own.id, "2.2", "person", "local", "mine");
  store.setRead("local", own.id, 99);
  store.startTurn("t", "a", "input");
  store.setBinding("team", "a");
  store.setArchived("a", true, MANUAL);
  assert.ok(store.getSession("a")!.archivedAt! > 0);
  store.setArchived("a", false, MANUAL);
  assert.equal(store.getSession("a")!.archivedAt, null);
  const h = heard(store);
  store.deleteSession("a");
  const told = h.changes.flatMap((c) =>
    c.type === "sessionRemoved" ? [`removed ${c.key}`] : c.type === "threadRemoved" ? [`thread removed ${c.id}`] : c.type === "thread" ? [`thread ${c.id}`] : [],
  );
  assert.deepEqual(told, ["removed a", `thread removed ${own.id}`, `thread ${shared.id}`]);
  assert.equal(store.getSession("a"), null);
  assert.equal(store.getThread(own.id), null);
  assert.deepEqual(store.entriesAfter(own.id, 0), []);
  assert.deepEqual(store.threadSessions(shared.id).map((m) => m.session), ["b"]);
  assert.equal(store.pendingMessages("b").length, 1, "the other session keeps its delivery");
  assert.deepEqual(store.listTurns("a"), []);
  assert.equal(store.binding("team"), null);
});

test("the store announces what changed", () => {
  const store = memory();
  const h = heard(store);
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  const [n] = say(store, thread.id, "1.2", "person", "local", "hi");
  store.deliver(thread.id, n, ["a"]);
  store.setRead("local", thread.id, n);
  store.recordProcess(42, 1, "claude", "x");
  store.forgetProcess(42);
  store.forgetProcess(42);
  const kinds = h.changes.map((c) => (["session", "thread", "read", "processes"].includes(c.type) ? c.type : "other"));
  assert.deepEqual(kinds, ["session", "session", "thread", "thread", "session", "read", "processes", "processes"]);
  assert.deepEqual(h.changes[2], { type: "thread", id: thread.id, entries: [] });
  const appended = h.changes[3]!;
  assert.ok(appended.type === "thread");
  assert.deepEqual([appended.id, appended.entries.map((e) => [e.n, e.text])], [thread.id, [[1, "hi"]]]);
  assert.deepEqual(h.changes[5], { type: "read", viewer: "local", thread: thread.id, n });
  h.stop();
  store.notify("a");
  assert.equal(h.changes.length, 8, "unsubscribed");
});

test("a session's own chat is archived with it, a chat of its own alone; anything new said brings them back", () => {
  const store = memory();
  session(store, "a");
  const own = store.openThreadOf("ember", "EMBER", "1.1", null, null, "a");
  const other = store.openThread("ember", "EMBER", "2.1", null, null);
  store.joinThread(own.id, "a", "ember");
  store.joinThread(other.id, "a", "ember");
  say(store, other.id, "2.2", "person", "local", "hi");
  assert.equal(store.homeChat("a")!.id, own.id);
  assert.deepEqual(store.chatsOfTheirOwn().map((t) => t.id), [other.id]);
  const thread = (id: number) => store.getThread(id)!;
  const row = () => store.getSession("a")!;

  store.setArchived("a", true, AUTO);
  assert.deepEqual([row().archivedBy, thread(own.id).hiddenBy], [AUTO, AUTO]);
  assert.equal(thread(other.id).hiddenAt, null, "a chat of its own stays");
  // Its agent says something there: the session comes back, with its own chat.
  say(store, other.id, "2.3", "agent", "a", "done");
  assert.equal(row().archivedAt, null);
  assert.equal(row().shownAt, null, "brought back by what was said, not by hand");
  assert.equal(thread(own.id).hiddenAt, null);

  store.setThreadHidden(other.id, true, MANUAL);
  assert.ok(thread(other.id).hiddenAt !== null);
  assert.equal(row().archivedAt, null, "its sessions stay");
  assert.ok(existsSync(archiveFile(store, other.id)), "out of lists: in its archive file");
  assert.deepEqual(store.entriesAfter(other.id, 0).map((e) => e.text), ["hi", "done"]);
  // Someone writes in it: shown again.
  say(store, other.id, "2.4", "person", "local", "again");
  assert.equal(thread(other.id).hiddenAt, null);

  // Shown again by hand: the idle clock starts over.
  store.setArchived("a", true, MANUAL);
  store.setArchived("a", false, MANUAL);
  assert.ok(row().shownAt !== null);
});

test("a database made before archiving gains its columns and each session's first chat is its own", () => {
  const path = join(tempdir(), "ember.db");
  const db = new DatabaseSync(path);
  const old = SCHEMA.replace("  archived_at INTEGER,\n  archived_by TEXT,\n  shown_at INTEGER,\n  cwd TEXT\n", "  archived_at INTEGER\n").replace(
    "  home TEXT,\n  hidden_at INTEGER,\n  hidden_by TEXT,\n  shown_at INTEGER,\n",
    "",
  );
  assert.ok(!old.includes("hidden_at"));
  db.exec(old);
  db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
  db.exec(`INSERT INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, archived_at)
             VALUES ('a', 'ember', 'all', 'claude', 'cc', '/w/a', 'a', 1, 1, 5);
           INSERT INTO threads (id, surface, channel, thread_ts, created_at) VALUES (1, 'ember', 'EMBER', '1.1', 1), (2, 'ember', 'EMBER', '2.1', 2);
           INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (1, 'a', 'ember', 1), (2, 'a', 'ember', 2);`);
  db.close();
  const store = open(path);
  const first = store.getThread(1)!;
  assert.deepEqual([first.home, first.hiddenAt, first.hiddenBy], ["a", 5, MANUAL]);
  assert.equal(store.getThread(2)!.home, null);
  assert.equal(store.getSession("a")!.archivedBy, MANUAL);
  store.close();
  // Opened again: nothing more to add.
  open(path);
});

test("a database made before clients gains the column and a message keeps its app through archiving", () => {
  const dir = tempdir();
  const path = join(dir, "ember.db");
  const db = new DatabaseSync(path);
  const old = SCHEMA.replace("  client TEXT,\n", "");
  assert.ok(!old.includes("client"));
  db.exec(old);
  // The view as it was made before.
  db.exec(MERGED.replace("m.declared, m.client, m.agent_identity,", "m.declared,"));
  db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
  db.close();
  const store = open(path, join(dir, "archive"));
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  say(store, thread.id, "1.2", "person", "local", "旧的");
  const [n] = store.insertMessage({ ...newMessage(thread.id, "1.3", "person", "local", "新的"), client: "android 0.1.1123" });
  store.deliver(thread.id, n, ["a"]);
  const clients = () => store.messagesBefore(thread.id, null, 10).map((m) => m.client);
  assert.deepEqual(clients(), [null, "android 0.1.1123"]);
  assert.equal(store.pendingMessages("a")[0]!.message.client, "android 0.1.1123");
  store.setArchived("a", true, MANUAL);
  assert.ok(existsSync(archiveFile(store, thread.id)));
  assert.deepEqual(clients(), [null, "android 0.1.1123"]);
  store.setArchived("a", false, MANUAL);
  assert.deepEqual(clients(), [null, "android 0.1.1123"]);
  store.close();
  open(path);
});

test("a widget's state is kept by session and path, its model told once until it changes", () => {
  const store = memory();
  session(store, "a");
  session(store, "b");
  const thread = store.openThread("ember", "EMBER", "3.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  const path = "/w/a/uploads/pick.html";
  store.insertMessage({ ...newMessage(thread.id, "3.2", "agent", "a", "![](pick.html)"), attachments: [{ name: "pick.html", path, size: 9 }] });
  assert.equal(store.widgetState("a", path), null);
  store.putWidgetState("a", path, `{"modelContent":"red"}`, "red");
  store.putWidgetState("a", "/w/a/uploads/quiet.html", `{"privateContent":1}`, null);
  assert.equal(store.widgetState("a", path), `{"modelContent":"red"}`);
  assert.equal(store.widgetState("b", path), null, "kept per session");
  assert.deepEqual(store.untoldWidgetModels("a"), [{ path, name: "pick.html", thread: ["EMBER", "3.1"], model: "red" }]);
  store.markWidgetModelsTold("a", [[path, "red"]]);
  assert.deepEqual(store.untoldWidgetModels("a"), []);
  // The same model again is not news; another is, and one changed after it was read is not marked told.
  store.putWidgetState("a", path, `{"modelContent":"red","privateContent":2}`, "red");
  assert.deepEqual(store.untoldWidgetModels("a"), []);
  store.putWidgetState("a", path, `{"modelContent":"blue"}`, "blue");
  store.markWidgetModelsTold("a", [[path, "red"]]);
  assert.deepEqual(store.untoldWidgetModels("a").map((w) => w.model), ["blue"]);
  // A file no message of the session's threads carries: its path's name, no thread.
  store.putWidgetState("a", "/elsewhere/x.html", "{}", "x");
  const elsewhere = store.untoldWidgetModels("a").find((w) => w.path === "/elsewhere/x.html")!;
  assert.deepEqual([elsewhere.name, elsewhere.thread], ["x.html", null]);
  store.deleteSession("a");
  assert.equal(store.widgetState("a", path), null);
});

test("session fast migrates old databases and survives restart", () => {
  const path = join(tempdir(), "ember.db");
  let store = open(path);
  session(store, "old");
  store.close();
  const db = new DatabaseSync(path);
  db.exec("ALTER TABLE sessions DROP COLUMN fast");
  db.close();
  store = open(path);
  assert.equal(store.getSession("old")!.fast, null);
  store.setSessionFast("old", false);
  store.close();
  store = open(path);
  assert.equal(store.getSession("old")!.fast, false);
});

test("the latest turn is the last inserted when start times tie", () => {
  const store = memory();
  session(store, "same-ms");
  store.startTurn("first", "same-ms", "input");
  store.endTurn("first", "failed", "rate_limit: quota", null, null);
  store.startTurn("second", "same-ms", "resume");
  store.endTurn("second", "completed", null, null, null);
  store.db.exec("UPDATE turns SET started_at = 123 WHERE session_key = 'same-ms'");
  const latest = store.lastTurn("same-ms")!;
  assert.equal(latest.kind, "resume");
  assert.equal(latest.outcome, "completed");
  assert.equal(latest.detail, null);
});

test("a message keeps its model after switching, editing and archiving", () => {
  const dir = tempdir();
  const store = open(join(dir, "ember.db"), join(dir, "archive"));
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  store.setSessionModel("a", "gpt-6-sol", "high");
  say(store, thread.id, "1.2", "agent", "a", "first");
  store.setSessionModel("a", "gpt-6-astra", "medium");
  say(store, thread.id, "1.3", "agent", "a", "second");
  store.editMessage("ember", "EMBER", "1.1", "1.2", "edited");
  const check = () => {
    const messages = store.messagesBefore(thread.id, null, 10);
    assert.equal(messages[0]!.agentIdentity.model, "gpt-6-sol");
    assert.equal(messages[0]!.agentIdentity.effort, "high");
    assert.equal(messages[0]!.agentIdentity.runtime, undefined);
    assert.equal(messages[1]!.agentIdentity.model, "gpt-6-astra");
    assert.equal(messages[0]!.text, "edited");
  };
  check();
  store.setArchived("a", true, MANUAL);
  check();
  store.setArchived("a", false, MANUAL);
  check();
});

test("an existing client view gains model identity even after a partial upgrade", () => {
  for (const alreadyAdded of [false, true]) {
    const path = join(tempdir(), "ember.db");
    const db = new DatabaseSync(path);
    db.exec(SCHEMA);
    // The immediately previous release already had client, but no model snapshot.
    db.exec(MERGED.replace("m.agent_identity, ", ""));
    // The broken upgrade added the column while leaving this old view in place.
    if (alreadyAdded) db.exec("ALTER TABLE entries ADD COLUMN agent_identity TEXT");
    db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    db.exec(`INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, client, at) VALUES (1, 1, 'message', '1.1', 'person', 'local', 'kept', 'android old', 100)`);
    db.exec(`INSERT INTO entries (thread, n, kind, target, author_kind, author, text, at) VALUES (1, 2, 'edit', 1, 'person', 'local', 'edited', 200)`);
    db.close();
    // Both the first upgrade and subsequent opens must keep existing data readable.
    for (let i = 0; i < 2; i++) {
      const store = open(path);
      const message = store.messageAt(1, "1.1")!;
      assert.equal(message.text, "edited");
      assert.equal(message.client, "android old");
      assert.equal(message.editedAt, 200);
      assert.equal(message.agentIdentity, null, "do not backfill old messages");
      assert.deepEqual(store.messagesBefore(1, null, 10), [message]);
      assert.deepEqual(store.lastMessage(1), message);
      store.close();
    }
  }
});

test("canonical and legacy system authors are read as the same kind", () => {
  const store = memory();
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.db.exec(`INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (${thread.id}, 1, 'message', '1.1', 'stillfail', 'stillfail', 'x', 1)`);
  say(store, thread.id, "1.2", "ember", "ember", "y");
  assert.deepEqual(store.entriesAfter(thread.id, 0).map((e) => e.authorKind), ["ember", "ember"]);
  // Writes keep the legacy spelling.
  assert.equal((store.db.prepare("SELECT author_kind FROM entries WHERE n = 2").get() as any).author_kind, "ember");
});

// ── beyond tests.rs ──

test("an options card is kept as options too, and a choice that closes it ends the need", () => {
  const store = memory();
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  const card = { type: "options", options: [{ label: "合并", action: "close" }, { label: "再看" }] };
  store.startTurnFor("t1", "a", "input", { profile: "cc", person: "local", thread: thread.id });
  const [n] = store.insertMessage({ ...newMessage(thread.id, "1.2", "agent", "a", "合并吗？"), card });
  const row = store.db.prepare("SELECT card, options FROM entries WHERE n = ?").get(n) as any;
  assert.deepEqual([JSON.parse(row.card), JSON.parse(row.options)], [card, card.options]);
  assert.deepEqual(store.pendingCard(thread.id)![1], card);
  // Old style: options alone become an options card.
  const [m] = store.insertMessage({ ...newMessage(thread.id, "1.3", "agent", "a", "选一个"), options: [{ label: "x" }] });
  assert.deepEqual(store.entriesBetween(thread.id, m, m)[0]!.card, { type: "options", options: [{ label: "x" }] });
  assert.equal(store.closeCard("local", thread.id, n, "合并"), false, "not the latest card");
  // Back to one card: a fresh thread.
  const t2 = store.openThread("ember", "EMBER", "2.1", null, null);
  store.joinThread(t2.id, "a", "ember");
  const [k] = store.insertMessage({ ...newMessage(t2.id, "2.2", "agent", "a", "合并吗？"), card });
  assert.equal(store.closeCard("local", t2.id, k, "合并"), false, "the agent is still composing (its turn runs)");
  store.setAbout("t1", [t2.id, k, "2.2"]);
  store.endTurn("t1", "completed", null, "need_help", null);
  assert.equal(store.closeCard("local", t2.id, k, "再看"), false, "a reply option does not close");
  const h = heard(store);
  assert.equal(store.closeCard("local", t2.id, k, "合并", "en"), true);
  assert.deepEqual(h.changes, [{ type: "session", key: "a" }, { type: "thread", id: t2.id, entries: [] }]);
  const last = store.lastTurn("a")!;
  assert.deepEqual([last.declared, last.ending, last.need], ["final", "all_done", "Chose “合并”"]);
  assert.equal(store.pendingCard(t2.id), null);
  assert.equal(store.closeCard("local", t2.id, k, "合并"), true, "closing again is no change");
  assert.equal(h.changes.length, 2);
  const answers = store.answersSince(0);
  assert.deepEqual(answers.map((a) => [a.question.n, a.by, a.answer]), [[k, "local", null]]);
  h.stop();
});

test("an agent withdraws its own card only", () => {
  const store = memory();
  session(store, "a");
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  const [n] = store.insertMessage({ ...newMessage(thread.id, "1.2", "agent", "a", "?"), card: { type: "text" } });
  assert.equal(store.withdrawCard("b", thread.id, "1.2"), false);
  assert.equal(store.withdrawCard("a", thread.id, "1.2"), true);
  assert.equal(store.pendingCard(thread.id), null);
  assert.deepEqual(store.answersSince(0), [], "withdrawn is not answered");
  assert.ok(n > 0);
});

test("a turn nobody's message started goes on with the work of the one before; a wait stopped is aborted", () => {
  const store = memory();
  session(store, "a");
  assert.equal(store.hasTurns("a"), false);
  store.startTurnFor("t1", "a", "input", { profile: "cc", person: "me@x", thread: 7 });
  store.endTurn("t1", "completed", null, "waiting", 60);
  store.setWaitFor("t1", "CI");
  // Turns started in the same ms tie in ORDER BY started_at (as in the Rust): keep them apart.
  store.db.exec("UPDATE turns SET started_at = started_at - 1000 WHERE id = 't1'");
  store.startTurn("t2", "a", "nudge");
  const t2 = store.db.prepare("SELECT profile, person, thread FROM turns WHERE id = 't2'").get() as any;
  assert.deepEqual({ ...t2 }, { profile: null, person: "me@x", thread: 7 });
  assert.equal(store.stopWait("a"), false, "the latest turn is not waiting");
  store.endTurn("t2", "completed", null, "waiting", 30);
  assert.equal(store.stopWait("a"), true);
  const last = store.lastTurn("a")!;
  assert.deepEqual([last.outcome, last.declared, last.waitSeconds, last.detail], ["aborted", null, null, "other: stopped while waiting"]);
  assert.equal(store.listTurns("a")[0]!.summary.waitFor, "CI");
  assert.equal(store.toldNotes("a") > 0, true, "a new session was told every note");
  store.setToldNotes("a", 3);
  assert.equal(store.toldNotes("a"), 3);
  const stats = store.sessionStats(null).get("a")!;
  assert.deepEqual([stats.turns, stats.lastTurn!.outcome], [2, "aborted"]);
});

test("bindings tell both sessions; delivered can be taken back", () => {
  const store = memory();
  session(store, "a");
  session(store, "b");
  const h = heard(store);
  store.setBinding("team", "b");
  store.setBinding("team", "a");
  assert.deepEqual(h.changes, [{ type: "session", key: "b" }, { type: "session", key: "a" }, { type: "session", key: "b" }]);
  assert.deepEqual([...store.listBindings()], [["a", ["team"]]]);
  h.stop();
  const thread = store.openThread("ember", "EMBER", "1.1", null, null);
  store.joinThread(thread.id, "a", "ember");
  const [n] = say(store, thread.id, "1.2", "person", "local", "hi");
  store.deliver(thread.id, n, ["a"]);
  store.markDelivered("a", [[thread.id, n]]);
  assert.deepEqual([...store.heardThreads("a")], [thread.id]);
  store.markUndelivered("a", [[thread.id, n]]);
  assert.equal(store.pendingMessages("a").length, 1);
  assert.deepEqual([...store.heardThreads("a")], []);
});

test("jobs: started, said, ended and cleared", () => {
  const store = memory();
  session(store, "a");
  const job: JobRow = {
    id: "j1", sessionKey: "a", name: "build", command: "make", cwd: "/w/a", port: null, token: "tok", state: "running", pgid: 10,
    exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "/w/a/j1.log", watch: true,
  };
  const h = heard(store);
  store.insertJob(job);
  assert.deepEqual(store.getJob("j1"), job);
  assert.equal(store.jobByToken("tok")!.id, "j1");
  for (let i = 0; i < 55; i++) store.addJobNotice("j1", `n${i}`);
  assert.equal(store.jobNotices("j1", 100).length, 50);
  assert.equal(store.jobNotices("j1", 1)[0]!.text, "n54");
  store.jobStarted("j1", 11, true);
  assert.deepEqual([store.getJob("j1")!.pgid, store.getJob("j1")!.restarts], [11, 1]);
  store.jobEnded("j1", "exited", 0);
  assert.deepEqual(store.clearEndedJobs("a"), [["j1", "/w/a/j1.log"]]);
  assert.deepEqual(store.listJobs(null), []);
  assert.deepEqual(h.changes.slice(-2), [{ type: "session", key: "a" }, { type: "jobRemoved", id: "j1", session: "a" }]);
  h.stop();
});

test("usage: a call is recorded once, its output grown; turns tell whom they were for", () => {
  const store = memory();
  session(store, "a");
  store.startTurnFor("t1", "a", "input", { profile: "cc", person: "me@x", thread: 3 });
  const call = { id: "c1", at: 1000, model: "m", subagent: false, fast: true, input: 1, cacheRead: 2, cacheWrite: 3, cacheWriteLong: 4, output: 5 };
  const of = { turn: "t1", person: "me@x", thread: 3, profile: "cc" };
  assert.equal(store.recordUsage("/t.jsonl", { session: "a", offset: 10, model: "m" }, "claude", [[call, of]]), 1);
  assert.equal(store.recordUsage("/t.jsonl", { session: "a", offset: 20, model: "m" }, "claude", [[{ ...call, output: 9 }, of]]), 0);
  assert.deepEqual(store.usageFiles().get("/t.jsonl"), { session: "a", offset: 20, model: "m" });
  const [g] = store.usageGroups(0, 2000, 0);
  assert.deepEqual([g!.calls, g!.output, g!.fast, g!.day], [1, 9, true, "1970-01-01"]);
  assert.equal(store.usageSince(), 1000);
  assert.deepEqual(store.usageTurns("a").map((t) => [t.id, t.of.person, t.of.thread, t.of.profile]), [["t1", "me@x", 3, "cc"]]);
  assert.deepEqual(store.usageActiveSessions(0), ["a"]);
  const h = heard(store);
  store.usageChanged();
  assert.deepEqual(h.changes, [{ type: "usage" }]);
  h.stop();
});
