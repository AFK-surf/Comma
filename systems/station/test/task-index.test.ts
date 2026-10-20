// The Task index (store.ts `the Task index`): a row for each chat on the station's page and for nothing else, its status
// as the chat and a person's mark make it, a new rev for each change and none without one, tombstones for deleted chats,
// and an index made on open for the chats from before it. A store on a TestClock.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { MANUAL, Store, TASK_ACTIVITY_EVERY_MS, TASK_TITLE_MAX, newMessage } from "../src/store/store.ts";
import { TASK_CHANNEL, TASK_SURFACE } from "../src/tasks/names.ts";
import { testClock } from "./hub-fakes.ts";

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

function rig(path = ":memory:") {
  const time = testClock();
  const store = Store.open(path, null, time.clock);
  stores.push(store);
  return { store, time };
}

function session(store: Store, key: string, model: string | null = null) {
  store.insertSession({ key, connect: "ds", runtime: "claude", profile: "cc", model, workspace: `/w/${key}`, token: key, createdAt: 1, lastActiveAt: 1 });
}

/// A chat on the page with its own session.
function chat(store: Store, ts: string, key: string) {
  session(store, key, "opus");
  const thread = store.openThreadOf("ember", "EMBER", ts, null, "a@x", key);
  store.joinThread(thread.id, key, "ember");
  return thread.id;
}

const rows = (store: Store) => store.taskIndexSince(0, 1000);
const row = (store: Store, thread: number) => {
  const r = rows(store).find((x) => x.thread === thread);
  return r === undefined ? undefined : { ...JSON.parse(r.json), removed: r.removed };
};

test("a chat on the page has a row; a Slack thread and another station's Task taken part in here have none", async () => {
  const { store } = rig();
  const id = chat(store, "1.1", "s1");
  const slack = store.openThread("slack:T1", "C1", "2.2", null, null);
  const elsewhere = store.openThread(TASK_SURFACE, TASK_CHANNEL, "3.3", null, null);
  store.joinThread(elsewhere.id, "s1", "task");
  store.insertMessage(newMessage(slack.id, "2.3", "person", "U1", "hello"));
  store.insertMessage(newMessage(elsewhere.id, "3.4", "person", "b@x", "hi"));
  store.insertMessage(newMessage(id, "1.2", "person", "a@x", "  fix   the\nbuild  "));
  assert.deepEqual(rows(store).map((r) => r.thread), [id]);
  const r = row(store, id);
  assert.deepEqual(r, {
    task: "EMBER/1.1", thread: id, title: "fix the", status: "in_progress", created_by: "a@x", created_at: 0, last_activity_at: 0,
    runtime: "claude", model: "opus", labels: [], rev: r.rev, removed: false,
  });
  assert.equal(store.taskStatus(slack.id), null);
  assert.equal(store.taskStatus(elsewhere.id), null);
  assert.equal(store.setTaskStatus(elsewhere.id, "done"), null);
  assert.deepEqual(rows(store).map((r) => r.thread), [id]);
});

test("a Task's status: derived from its agent and its cards, marked by a person, archived with its chat", async () => {
  const { store } = rig();
  const id = chat(store, "1.1", "s1");
  const status = () => store.taskStatus(id);
  assert.equal(status(), "in_progress");
  store.insertMessage(newMessage(id, "1.2", "person", "a@x", "go"));
  store.startTurn("t1", "s1", "input");
  assert.equal(status(), "in_progress");
  store.endTurn("t1", "completed", null, "all_done", null);
  assert.equal(status(), "needs_review", "its agent says it is finished");
  store.insertMessage(newMessage(id, "1.3", "person", "a@x", "one more thing"));
  store.startTurn("t2", "s1", "input");
  assert.equal(status(), "in_progress", "at work again");
  store.endTurn("t2", "completed", null, "need_help", null);
  assert.equal(status(), "needs_review", "its agent needs a person");
  store.insertMessage(newMessage(id, "1.4", "person", "a@x", "do it this way"));
  store.startTurn("t3", "s1", "input");
  store.insertMessage({ ...newMessage(id, "1.5", "agent", "s1", "deploy?"), card: { type: "options", options: [{ label: "yes" }] } });
  store.endTurn("t3", "completed", null, null, null);
  assert.equal(status(), "needs_review", "a card waits for an answer");

  // Marked by a person: kept through the agent's posts, taken away by a person writing in it.
  assert.equal(store.setTaskStatus(id, "done"), "done");
  store.insertMessage(newMessage(id, "1.6", "agent", "s1", "closing note"));
  assert.equal(status(), "done");
  store.insertMessage(newMessage(id, "1.7", "person", "a@x", "wait, also this"));
  assert.equal(status(), "in_progress");
  assert.equal(store.setTaskStatus(id, "cancelled"), "cancelled");
  assert.equal(store.setTaskStatus(id, null), "in_progress", "in_progress takes the mark away");

  // Archived with its chat; shown again, it is what it was.
  assert.equal(store.setTaskStatus(id, "cancelled"), "cancelled");
  store.setArchived("s1", true, MANUAL);
  assert.equal(status(), "archived");
  store.setArchived("s1", false, MANUAL);
  assert.equal(status(), "cancelled");
  store.setThreadHidden(id, true, MANUAL);
  assert.equal(status(), "archived");
  store.setThreadHidden(id, false, MANUAL);
  assert.equal(status(), "cancelled");
});

test("a Task's labels: set by a person, carried in its row at the next rev, gone with the Task", async () => {
  const { store } = rig();
  const id = chat(store, "1.1", "s1");
  assert.deepEqual(row(store, id)?.labels, [], "a Task has none at first");
  const before = store.taskIndexRev();
  assert.deepEqual(store.setTaskLabels(id, ["lbl_b", "lbl_a", "lbl_b"]), ["lbl_a", "lbl_b"]);
  assert.deepEqual(row(store, id)?.labels, ["lbl_a", "lbl_b"]);
  assert.ok(store.taskIndexRev() > before);
  // The same labels again change nothing.
  const set = store.taskIndexRev();
  store.setTaskLabels(id, ["lbl_a", "lbl_b"]);
  assert.equal(store.taskIndexRev(), set);
  // A person's mark and the labels are kept apart.
  store.setTaskStatus(id, "done");
  assert.deepEqual(row(store, id)?.labels, ["lbl_a", "lbl_b"]);
  assert.deepEqual(store.setTaskLabels(id, []), []);
  assert.deepEqual(row(store, id)?.labels, []);
  // A thread that is not a Task of this station takes none.
  const slack = store.openThread("slack:T1", "C1", "9.9", null, null);
  assert.equal(store.setTaskLabels(slack.id, ["lbl_a"]), null);
});

test("each change takes the index's next rev, read in pages; what changes nothing in a row takes none", async () => {
  const { store } = rig();
  const a = chat(store, "1.1", "s1");
  const b = chat(store, "2.1", "s2");
  const before = store.taskIndexRev();
  store.setRead("a@x", a, 0);
  store.setPin("a@x", "s1", true);
  assert.equal(store.taskIndexRev(), before, "nothing a row shows changed");
  store.setThreadTitle(a, "named");
  store.setTaskStatus(b, "done");
  store.setSessionModel("s1", "sonnet", null);
  const all = rows(store);
  assert.deepEqual(all.map((r) => r.thread), [b, a]);
  const revs = all.map((r) => r.rev);
  assert.ok(revs[0]! < revs[1]!);
  assert.equal(store.taskIndexRev(), revs[1]);
  assert.deepEqual(JSON.parse(all[1]!.json).rev, revs[1]);
  assert.deepEqual([JSON.parse(all[1]!.json).title, JSON.parse(all[1]!.json).model], ["named", "sonnet"]);
  // Paged by rev: after what was read, at most `limit`.
  assert.deepEqual(store.taskIndexSince(0, 1).map((r) => r.thread), [b]);
  assert.deepEqual(store.taskIndexSince(revs[0]!, 1).map((r) => r.thread), [a]);
  assert.deepEqual(store.taskIndexSince(revs[1]!, 10), []);
});

test("a Task's title: the name it was given, else the first line a person wrote, cut to its most", async () => {
  const { store } = rig();
  const id = chat(store, "1.1", "s1");
  assert.equal(row(store, id).title, null);
  store.insertMessage(newMessage(id, "1.2", "person", "a@x", `\n\n${"word ".repeat(40)}\nsecond line`));
  assert.equal(row(store, id).title, "word ".repeat(TASK_TITLE_MAX / 5).trimEnd());
  store.setAutoTitle(id, "  the agent's name  ", false);
  assert.equal(row(store, id).title, "the agent's name");
  store.setThreadTitle(id, "é".repeat(200));
  assert.equal(row(store, id).title, "é".repeat(TASK_TITLE_MAX));
});

test("last_activity_at moves at most once every 10 s", async () => {
  const { store, time } = rig();
  const id = chat(store, "1.1", "s1");
  const activity = () => row(store, id).last_activity_at;
  const say = (ts: string) => store.insertMessage(newMessage(id, ts, "person", "a@x", "x"));
  await time.adjust(1_000);
  say("1.2");
  assert.equal(activity(), 0, "within 10 s of its creation");
  const rev = store.taskIndexRev();
  await time.adjust(TASK_ACTIVITY_EVERY_MS);
  say("1.3");
  assert.equal(activity(), 11_000);
  assert.ok(store.taskIndexRev() > rev);
  await time.adjust(5_000);
  say("1.4");
  assert.equal(activity(), 11_000);
  await time.adjust(5_000);
  say("1.5");
  assert.equal(activity(), 21_000);
});

test("a deleted Task leaves a tombstone at the next rev, forgotten once pruned through it", async () => {
  const { store } = rig();
  const a = chat(store, "1.1", "s1");
  const b = chat(store, "2.1", "s2");
  store.deleteSession("s1");
  const tomb = rows(store).find((r) => r.thread === a)!;
  assert.equal(tomb.removed, true);
  assert.deepEqual(JSON.parse(tomb.json), { task: "EMBER/1.1", thread: a, removed: true, rev: tomb.rev });
  assert.equal(tomb.rev, store.taskIndexRev());
  assert.equal(store.taskStatus(a), null);
  assert.equal(store.pruneTaskIndexTombstones(tomb.rev - 1), 0, "not yet told");
  assert.equal(store.pruneTaskIndexTombstones(tomb.rev), 1);
  assert.deepEqual(rows(store).map((r) => r.thread), [b]);
  // The rev goes on from where it was, though the row with the last one is gone.
  store.setThreadTitle(b, "after");
  assert.equal(row(store, b).rev, tomb.rev + 1);
});

test("the index of a database from before it is made on open, with every chat on the page; its epoch stays", async () => {
  const dir = mkdtempSync(join(tmpdir(), "task-index-"));
  dirs.push(dir);
  const path = join(dir, "stillfail.db");
  const first = rig(path);
  const live = chat(first.store, "1.1", "s1");
  first.store.insertMessage(newMessage(live, "1.2", "person", "a@x", "live one"));
  const archived = chat(first.store, "2.1", "s2");
  first.store.insertMessage(newMessage(archived, "2.2", "person", "a@x", "archived one"));
  first.store.setThreadHidden(archived, true, MANUAL);
  const slack = first.store.openThread("slack:T1", "C1", "3.3", null, null);
  first.store.insertMessage(newMessage(slack.id, "3.4", "person", "U1", "hello"));
  first.store.close();
  // A station's database before the index.
  const db = new DatabaseSync(path);
  db.exec("DROP TABLE task_index; DROP TABLE meta;");
  db.close();

  const second = rig(path);
  const epoch = second.store.taskIndexEpoch();
  assert.match(epoch, /^[0-9a-f]{32}$/);
  assert.deepEqual(
    rows(second.store).map((r) => [r.thread, JSON.parse(r.json).title, JSON.parse(r.json).status]),
    [[live, "live one", "in_progress"], [archived, "archived one", "archived"]],
  );
  const rev = second.store.taskIndexRev();
  second.store.close();

  // Opened again: the same epoch and rows, no rev taken.
  const third = rig(path);
  assert.equal(third.store.taskIndexEpoch(), epoch);
  assert.equal(third.store.taskIndexRev(), rev);
});
