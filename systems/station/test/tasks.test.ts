// Tasks between stations (src/tasks/tasks.ts): a Task kept on station A, a Session of station B taking part in it.
// The two hubs' requests go to each other directly, as the station transport would carry them.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { threadAddress } from "../src/agents/instructions.ts";
import { Unreachable } from "../src/jobs/remote.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { type Call, FILE_PART, PUT_LIMIT, TASK_SURFACE, Tasks } from "../src/tasks/tasks.ts";
import { makeStore } from "../src/read/store.ts";
import { entries } from "../src/read/views.ts";
import { thread as threadView } from "../src/read/sessions.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

type Json = any;

/// Whether session `key`'s agent was given `text` (handed to it, or still to be).
function heard(rig: Rig, key: string, text: string): boolean {
  const given = rig.claude.sessions.filter((a) => a.options.route === key).flatMap((a) => [...a.prompts, ...a.steers]);
  return given.some((p) => p.includes(text)) || rig.store.pendingMessages(key).some((p) => p.message.text === text);
}

/// How many times session `key`'s agent was given `text`.
function times(rig: Rig, key: string, text: string): number {
  const given = rig.claude.sessions.filter((a) => a.options.route === key).flatMap((a) => [...a.prompts, ...a.steers]);
  return given.filter((p) => p.includes(text)).length + rig.store.pendingMessages(key).filter((p) => p.message.text === text).length;
}

function stations(o: { clock?: ReturnType<typeof testClock> } = {}) {
  const a = new Rig({ clock: o.clock?.clock });
  const b = new Rig({ clock: o.clock?.clock });
  const asked: [string, string, Json][] = [];
  // How B is now: here, away (cannot be reached), or reached but not answering. `lose`: a request answered whose
  // answer does not get back.
  const state = { b: "here" as "here" | "away" | "silent", lose: (_from: string, _request: Json) => false };
  let tasksA: Tasks;
  let tasksB: Tasks;
  // `from` asks `to`: what the transport would carry, with who asks.
  const call =
    (from: string): Call =>
    async (to, request) => {
      asked.push([from, to, request]);
      if ((to === "B" || from === "B") && state.b === "away") throw new Unreachable("peer unavailable");
      if (to === "B" && state.b === "silent") throw new Error("peer request timed out");
      const there = to === "A" ? tasksA : to === "B" ? tasksB : null;
      if (!there) throw new Unreachable(`no station ${to}`);
      const answer = JSON.parse(JSON.stringify(await there.handle(from, JSON.parse(JSON.stringify(request)))));
      if (state.lose(from, request)) throw new Error("peer request timed out");
      return answer;
    };
  tasksA = new Tasks(a.hub, () => call("A"));
  tasksB = new Tasks(b.hub, () => call("B"));
  for (const [rig, tasks] of [[a, tasksA], [b, tasksB]] as const) {
    rig.hub.setTasks(tasks);
    tasks.begin();
  }
  // A Task on A: a chat with a Session of A's, and what a person asked in it.
  const [keyA, chat] = newSession(a.hub, { runtime: "claude", createdBy: "ann@example.com", title: "release" });
  say(a.hub, chat.id, "ann@example.com", "build the release");
  const puts = () => asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.put").length;
  return { a, b, tasksA, tasksB, keyA, chat, asked, state, puts, close: async () => Promise.all([a.close(), b.close()]) };
}

/// B's thread of the Task its Session `key` takes part in.
const threadOf = (b: Rig, key: string) => b.store.threadsAt("TASK", b.store.sessionThreads(key)[0]!.thread.threadTs)[0]!;

test("a Session of another station takes part in a Task: it is given it, answers in it, and is given what comes after", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  // B started a Session for it, in a thread of its own, and was given the Task from its start.
  const thread = threadOf(s.b, keyB);
  assert.equal(thread.surface, TASK_SURFACE);
  assert.equal(thread.home, keyB);
  assert.deepEqual(
    s.b.said(thread.id).map((m) => [m.authorKind, m.author, m.text]),
    [["person", "ann@example.com", "build the release"]],
  );
  assert.ok(heard(s.b, keyB, "build the release"));
  // Asked again (an invite whose answer was lost): the same Session.
  assert.equal(await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com" }), keyB);

  // Its answer is written into the Task at A, handed to A's Session, and not handed back to B's.
  const answer = await s.b.call(keyB, "chat_post", { to: threadAddress(thread.channel, thread.threadTs), text: "built: 1.2.3", kind: "all_done", done: "built 1.2.3" });
  assert.ok(answer.startsWith("Posted to TASK/"), answer);
  await settle();
  const atA = s.a.said(s.chat.id).at(-1)!;
  assert.deepEqual([atA.authorKind, atA.author, atA.text], ["agent", `B/${keyB}`, "built: 1.2.3"]);
  assert.equal(s.a.store.entriesAfter(s.chat.id, atA.n - 1)[0]!.declared, "all_done");
  assert.ok(heard(s.a, s.keyA, "built: 1.2.3"));
  assert.deepEqual(
    s.b.said(thread.id).map((m) => [m.authorKind, m.author, m.text]),
    [
      ["person", "ann@example.com", "build the release"],
      ["agent", keyB, "built: 1.2.3"],
    ],
    "given back as its own, once",
  );
  assert.ok(!heard(s.b, keyB, "built: 1.2.3"));

  // What is said in the Task afterwards is given to B.
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  assert.equal(s.b.said(thread.id).at(-1)!.text, "now publish it");
  assert.ok(heard(s.b, keyB, "now publish it"));
  // B never asks for the Task: it is given it.
  assert.equal(s.asked.filter(([from, , r]) => from === "B" && r.method !== "task.post").length, 0);
  await s.close();
});

// What an agent finished (chat_post milestones) goes with its Message between stations: into the Task at its host, back
// to the station whose Session posted it, and on to the others. Milestones alone are handed to no Session there.
test("milestones go with a Task's Messages between stations; milestones alone are handed to no Session", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  const thread = threadOf(s.b, keyB);
  const to = threadAddress(thread.channel, thread.threadTs);
  const handed = (rig: Rig, id: number, n: number) => (rig.store.db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ? AND n = ?").get(id, n) as Json).c;
  const kept = (rig: Rig, id: number) =>
    rig.store
      .entriesAfter(id, 0)
      .filter((e) => e.authorKind === "agent")
      .map((e) => [e.kind, e.author, e.text, e.milestones]);
  assert.equal(await s.b.call(keyB, "chat_post", { to, milestones: ["Built the release"] }), `Recorded a milestone in the Activity of ${to}.`);
  await s.b.call(keyB, "chat_post", { to, text: "published 1.2.3", milestones: ["Published 1.2.3"] });
  await settle();
  // At the host: written as B's Session's; the Message with words is handed to A's Session, the milestones alone are not.
  assert.deepEqual(kept(s.a, s.chat.id), [
    ["milestone", `B/${keyB}`, null, ["Built the release"]],
    ["message", `B/${keyB}`, "published 1.2.3", ["Published 1.2.3"]],
  ]);
  const [alone, published] = s.a.store.entriesAfter(s.chat.id, 0).filter((e) => e.authorKind === "agent");
  assert.equal(handed(s.a, s.chat.id, alone!.n), 0);
  assert.equal(handed(s.a, s.chat.id, published!.n), 1);
  // A's Session records one alone: given to B as written, handed to B's Session no more than B's own were.
  await s.a.call(s.keyA, "chat_post", { to: threadAddress(s.chat.channel, s.chat.threadTs), milestones: ["Checked the release notes"] });
  await settle();
  assert.deepEqual(kept(s.b, thread.id), [
    ["milestone", keyB, null, ["Built the release"]],
    ["message", keyB, "published 1.2.3", ["Published 1.2.3"]],
    ["milestone", s.keyA, null, ["Checked the release notes"]],
  ]);
  const atB = s.b.store.entriesAfter(thread.id, 0).at(-1)!;
  assert.equal(handed(s.b, thread.id, atB.n), 0);
  // Salix reads them with the Task's Messages; milestones alone have no words.
  const read = await s.tasksA.handle("salix", { method: "task.read", task: threadAddress(s.chat.channel, s.chat.threadTs), after: 0 });
  assert.deepEqual(
    read.messages.map((m: Json) => [m.author, m.text, m.milestones]),
    [
      ["ann@example.com", "build the release", undefined],
      [`B/${keyB}`, "", ["Built the release"]],
      [`B/${keyB}`, "published 1.2.3", ["Published 1.2.3"]],
      [s.keyA, "", ["Checked the release notes"]],
    ],
  );
  // A post of nothing at all is still refused.
  await assert.rejects(s.tasksA.handle("B", { method: "task.post", task: threadAddress(s.chat.channel, s.chat.threadTs), session: keyB, text: "", key: "k9" }), /text is required/);
  await s.close();
});

test("a put given again writes nothing twice and hands nothing twice", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const put = s.asked.find(([, , r]) => r.method === "task.put")![2];
  assert.deepEqual(await s.tasksB.handle("A", put), { through: put.through });
  await settle();
  assert.equal(s.b.said(threadOf(s.b, keyB).id).filter((m) => m.text === "build the release").length, 1);
  assert.equal(times(s.b, keyB, "build the release"), 1);
  await s.close();
});

test("a post asked again is one Message; a station whose Session takes no part writes nothing and is given nothing", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const task = threadAddress(s.chat.channel, s.chat.threadTs);
  const post = { method: "task.post", task, session: keyB, text: "half way", key: "k1" };
  const first = await s.tasksA.handle("B", post);
  assert.deepEqual(await s.tasksA.handle("B", post), first);
  assert.equal(s.a.said(s.chat.id).filter((m) => m.text === "half way").length, 1);
  await assert.rejects(s.tasksA.handle("C", { ...post, key: "k2" }), /takes no part/);
  await assert.rejects(s.tasksA.handle("B", { ...post, session: "other", key: "k2" }), /takes no part/);
  // A put of a Task B has no thread of: B does not know it (and, for a host from before `unknown`, it is gone).
  assert.deepEqual(await s.tasksB.handle("C", { method: "task.put", task, messages: [], through: 1 }), { unknown: true, gone: true });
  await s.close();
});

test("a station whose Sessions of a Task are gone is given nothing more of it", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  // B still has its thread of the Task, but no Session of it takes part any more.
  s.b.store.db.prepare("DELETE FROM thread_sessions WHERE session = ?").run(keyB);
  say(s.a.hub, s.chat.id, "ann@example.com", "anyone there?");
  await settle();
  assert.deepEqual(s.tasksA.taking(s.chat.id), []);
  const before = s.puts();
  say(s.a.hub, s.chat.id, "ann@example.com", "still?");
  await settle();
  assert.equal(s.puts(), before);
  assert.ok(!heard(s.b, keyB, "still?"));
  await s.close();
});

test("a station that cannot be reached is not asked again: what it missed is given once it says hello, however long after", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  s.state.b = "away";
  say(s.a.hub, s.chat.id, "ann@example.com", "said while B was away");
  say(s.a.hub, s.chat.id, "ann@example.com", "and this too");
  await settle();
  assert.ok(!heard(s.b, keyB, "said while B was away"));
  const tried = s.puts();
  await settle();
  assert.equal(s.puts(), tried, "not asked again on its own");
  // B is back: it tells A, which gives it what it missed, in order.
  s.state.b = "here";
  s.tasksB.connected();
  await settle();
  assert.deepEqual(
    s.b.said(threadOf(s.b, keyB).id).map((m) => m.text),
    ["build the release", "said while B was away", "and this too"],
  );
  assert.ok(heard(s.b, keyB, "and this too"));
  await s.close();
});

test("a station restored from before is given again what it lost, written once", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  say(s.a.hub, s.chat.id, "ann@example.com", "lost in the restore");
  await settle();
  const thread = threadOf(s.b, keyB);
  const lost = s.b.said(thread.id).at(-1)!;
  assert.equal(lost.text, "lost in the restore");
  // B's store goes back to before that Message: it has the Task only through the first.
  const first = s.b.said(thread.id)[0]!;
  s.b.store.db.prepare("DELETE FROM entries WHERE thread = ? AND n = ?").run(thread.id, lost.n);
  s.b.store.db.prepare("UPDATE tasks_elsewhere SET fetched = ?").run(Number(first.ts.split(".")[0]));
  s.tasksB.connected();
  await settle();
  assert.deepEqual(
    s.b.said(thread.id).map((m) => m.text),
    ["build the release", "lost in the restore"],
  );
  // What it had is not written again.
  const hello = s.asked.filter(([from, , r]) => from === "B" && r.method === "task.hello").at(-1)![2];
  assert.deepEqual(hello.tasks, [{ task: threadAddress(s.chat.channel, s.chat.threadTs), fetched: Number(first.ts.split(".")[0]) }]);
  assert.deepEqual(s.tasksA.taking(s.chat.id).map((t) => ({ ...t })), [{ station: "B", session: keyB }]);
  await s.close();
});

test("a station that lost the Task is invited again as it was first, and given it from its start", async () => {
  const s = stations();
  const start = { requester: "ann@example.com", title: "release", runtime: "claude" as const };
  const keyB = await s.tasksA.invite(s.chat.id, "B", start);
  await settle();
  // B lost everything of the Task: its hello names none.
  s.b.store.db.prepare("DELETE FROM tasks_elsewhere").run();
  assert.deepEqual(await s.tasksA.handle("B", { method: "task.hello", tasks: [] }), {});
  await settle();
  const invites = s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.invite").map(([, , r]) => r);
  assert.equal(invites.length, 2);
  assert.deepEqual(invites[1], invites[0], "invited again with what it was first invited with");
  // Its new Session takes the place of the old one, and is given the Task from its start.
  const [taking] = s.tasksA.taking(s.chat.id);
  assert.equal(s.tasksA.taking(s.chat.id).length, 1);
  assert.notEqual(taking!.session, keyB);
  assert.deepEqual(s.b.said(threadOf(s.b, taking!.session).id).map((m) => m.text), ["build the release"]);
  assert.ok(heard(s.b, taking!.session, "build the release"));
  // It takes part from then on.
  say(s.a.hub, s.chat.id, "ann@example.com", "welcome back");
  await settle();
  assert.ok(heard(s.b, taking!.session, "welcome back"));
  await s.close();
});

test("a station that lost the Task and is given what comes after says unknown, and is invited again", async () => {
  const s = stations();
  await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  s.b.store.db.prepare("DELETE FROM tasks_elsewhere").run();
  say(s.a.hub, s.chat.id, "ann@example.com", "after the loss");
  await settle();
  const [taking] = s.tasksA.taking(s.chat.id);
  assert.deepEqual(s.b.said(threadOf(s.b, taking!.session).id).map((m) => m.text), ["build the release", "after the loss"]);
  await s.close();
});

/// B loses everything of its Tasks elsewhere and says hello: A invites it again. Its new Session of the Task.
async function lostAndBack(s: ReturnType<typeof stations>): Promise<string> {
  s.b.store.db.prepare("DELETE FROM tasks_elsewhere").run();
  assert.deepEqual(await s.tasksA.handle("B", { method: "task.hello", tasks: [] }), {});
  await settle();
  return s.tasksA.taking(s.chat.id)[0]!.session;
}

/// What session `key`'s agent was given, in turns or still to be.
const givenTo = (rig: Rig, key: string) => [
  ...rig.claude.sessions.filter((a) => a.options.route === key).flatMap((a) => [...a.prompts, ...a.steers]),
  ...rig.store.pendingMessages(key).map((p) => p.message.text),
];

test("a station that lost a Task it had answered in is given it from its start and answers nothing again", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  const old = threadOf(s.b, keyB);
  await s.b.call(keyB, "chat_post", { to: threadAddress(old.channel, old.threadTs), text: "built: 1.2.3", kind: "all_done", done: "built 1.2.3" });
  await settle();
  const key = await lostAndBack(s);
  assert.notEqual(key, keyB);
  // The Task is in its new thread from its start; the answer is its Session's own, with what it declared.
  const thread = threadOf(s.b, key);
  assert.deepEqual(
    s.b.store.entriesAfter(thread.id, 0).filter((e) => e.kind === "message").map((e) => [e.authorKind, e.author, e.text, e.declared]),
    [
      ["person", "ann@example.com", "build the release", null],
      ["agent", key, "built: 1.2.3", "all_done"],
    ],
  );
  // What was answered is what was said before: no turn is started for it, and nothing waits.
  assert.deepEqual(givenTo(s.b, key), []);
  assert.equal(s.b.store.lastTurn(key), null);
  assert.equal(s.a.said(s.chat.id).filter((m) => m.authorKind === "agent" && m.author.startsWith("B/")).length, 1);
  // A invited it again saying through which Message it had answered (what it had been given when its Session ended
  // the turn), and said so with the put too, which named the Session that posted it, which B has no more.
  const invites = s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.invite").map(([, , r]) => r);
  const asked = s.a.said(s.chat.id).at(-2)!.n;
  assert.deepEqual(invites.map((r) => r.answered), [undefined, asked]);
  assert.equal(s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.put").at(-1)![2].answered, asked);
  const put = s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.put").at(-1)![2];
  assert.deepEqual(put.messages.map((m: Json) => m.author.session), [undefined, keyB]);
  // It takes part from then on.
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  assert.deepEqual(givenTo(s.b, key).filter((p) => p.includes("build the release")), []);
  assert.equal(times(s.b, key, "now publish it"), 1);
  await s.close();
});

test("a station that lost a Task is handed what was said after its last answer, once", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  const old = threadOf(s.b, keyB);
  await s.b.call(keyB, "chat_post", { to: threadAddress(old.channel, old.threadTs), text: "built: 1.2.3", kind: "all_done", done: "built 1.2.3" });
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  const key = await lostAndBack(s);
  assert.deepEqual(s.b.said(threadOf(s.b, key).id).map((m) => m.text), ["build the release", "built: 1.2.3", "now publish it"]);
  assert.equal(times(s.b, key, "now publish it"), 1);
  assert.equal(times(s.b, key, "build the release"), 0);
  assert.equal(times(s.b, key, "built: 1.2.3"), 0);
  await s.close();
});

test("a station that lost a long Task is handed nothing of what it answered, in however many puts it is given", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  for (let i = 0; i < PUT_LIMIT + 20; i++) say(s.a.hub, s.chat.id, "ann@example.com", `detail ${i}`);
  await settle();
  const old = threadOf(s.b, keyB);
  await s.b.call(keyB, "chat_post", { to: threadAddress(old.channel, old.threadTs), text: "built: 1.2.3", kind: "all_done", done: "built 1.2.3" });
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  const before = s.puts();
  const key = await lostAndBack(s);
  // The answer is in the second put: the first ends with Messages it answers.
  const puts = s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.put").slice(before).map(([, , r]) => r).filter((r) => r.messages.length > 0);
  const answer = puts.findIndex((r) => r.messages.some((m: Json) => m.text === "built: 1.2.3"));
  assert.ok(answer >= 2 && puts[answer - 1]!.messages.length === PUT_LIMIT, `the answer came in put ${answer} of ${puts.length}`);
  assert.equal(s.b.store.entriesAfter(threadOf(s.b, key).id, 0).filter((e) => e.kind === "message").length, PUT_LIMIT + 23);
  assert.deepEqual(givenTo(s.b, key).filter((p) => !p.includes("now publish it")), []);
  assert.equal(times(s.b, key, "now publish it"), 1);
  assert.equal(s.a.said(s.chat.id).filter((m) => m.authorKind === "agent" && m.author.startsWith("B/")).length, 1);
  await s.close();
});

/// A Task B's Session answered twice: what it was first asked, then `follow up`. B's thread of it, and the seqs.
async function answeredTwice(s: ReturnType<typeof stations>) {
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  const thread = threadOf(s.b, keyB);
  const to = threadAddress(thread.channel, thread.threadTs);
  await s.b.call(keyB, "chat_post", { to, text: "built: 1.2.3", kind: "all_done", done: "built 1.2.3" });
  await settle();
  say(s.a.hub, s.chat.id, "ann@example.com", "follow up");
  await settle();
  await s.b.call(keyB, "chat_post", { to, text: "followed up", kind: "all_done", done: "followed up" });
  await settle();
  const seq = (text: string) => Number(s.b.said(thread.id).find((m) => m.text === text)!.ts.split(".")[0]);
  return { keyB, thread, to, seq };
}

/// B is as it was when it had the Task through `fetched` only (restored from then), and says hello.
async function restored(s: ReturnType<typeof stations>, thread: number, fetched: number) {
  const db = s.b.store.db;
  const after = (db.prepare("SELECT n FROM entries WHERE thread = ? AND CAST(ts AS INTEGER) > ?").all(thread, fetched) as { n: number }[]).map((e) => e.n);
  for (const n of after) {
    db.prepare("DELETE FROM entries WHERE thread = ? AND n = ?").run(thread, n);
    db.prepare("DELETE FROM deliveries WHERE thread = ? AND n = ?").run(thread, n);
  }
  db.prepare("UPDATE tasks_elsewhere SET fetched = ?, answered = 0 WHERE thread = ?").run(fetched, thread);
  s.tasksB.connected();
  await settle();
}

test("a station restored from before an exchange it answered is given it again by put, and answers nothing again", async () => {
  const s = stations();
  const { keyB, thread, seq } = await answeredTwice(s);
  assert.equal(times(s.b, keyB, "follow up"), 1);
  const posts = () => s.a.store.entriesAfter(s.chat.id, 0).filter((e) => e.kind === "message" && e.author.startsWith("B/")).length;
  assert.equal(posts(), 2);
  // B goes back to before the follow-up: it still has the Task (no invite), with less of it.
  const invites = () => s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.invite").length;
  const before = invites();
  await restored(s, thread.id, seq("built: 1.2.3"));
  assert.equal(invites(), before);
  // A gave the follow-up and its answer again, saying it was answered: written, handed to no Session.
  const put = s.asked.filter(([from, to, r]) => from === "A" && to === "B" && r.method === "task.put").at(-1)![2];
  assert.deepEqual(put.messages.map((m: Json) => m.text), ["follow up", "followed up"]);
  assert.equal(put.answered, seq("follow up"));
  assert.deepEqual(
    s.b.store.entriesAfter(thread.id, 0).filter((e) => e.kind === "message").map((e) => [e.text, e.declared]).slice(-2),
    [["follow up", null], ["followed up", "all_done"]],
  );
  assert.equal(times(s.b, keyB, "follow up"), 1, "not handed over a second time");
  assert.equal(s.b.store.pendingMessages(keyB).length, 0);
  assert.equal(posts(), 2);
  await s.close();
});

test("a station restored from before is handed what was said after its last answer, once", async () => {
  const s = stations();
  const { keyB, thread, seq } = await answeredTwice(s);
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  assert.equal(times(s.b, keyB, "now publish it"), 1);
  await restored(s, thread.id, seq("built: 1.2.3"));
  assert.equal(times(s.b, keyB, "follow up"), 1);
  assert.equal(times(s.b, keyB, "now publish it"), 2, "handed over once more: its turn was lost");
  await s.close();
});

test("a station restored with a Message still waiting that was answered since hears it no more", async () => {
  const s = stations();
  const { keyB, thread, seq } = await answeredTwice(s);
  // B goes back to when the follow-up was handed to its Session and not heard yet.
  const followUp = s.b.said(thread.id).find((m) => m.text === "follow up")!;
  s.b.store.markUndelivered(keyB, [[thread.id, followUp.n]]);
  assert.deepEqual(s.b.store.pendingMessages(keyB).map((p) => p.message.text), ["follow up"]);
  await restored(s, thread.id, seq("follow up"));
  assert.deepEqual(s.b.store.pendingMessages(keyB), []);
  assert.equal(times(s.b, keyB, "follow up"), 1);
  await s.close();
});

test("a station that lost a Task after saying how far it was, without ending its turn, is handed what it was asked", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude" });
  await settle();
  const old = threadOf(s.b, keyB);
  await s.b.call(keyB, "chat_post", { to: threadAddress(old.channel, old.threadTs), text: "building…" });
  await settle();
  const key = await lostAndBack(s);
  const thread = threadOf(s.b, key);
  assert.deepEqual(s.b.said(thread.id).map((m) => [m.author, m.text]), [["ann@example.com", "build the release"], [key, "building…"]]);
  assert.equal(times(s.b, key, "build the release"), 1);
  assert.equal(times(s.b, key, "building…"), 0);
  await s.close();
});

test("a hello from a station from before `tasks` gives from what it was given, as before", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const before = s.puts();
  assert.deepEqual(await s.tasksA.handle("B", { method: "task.hello" }), {});
  await settle();
  assert.equal(s.puts(), before, "nothing it has not had: nothing given");
  assert.deepEqual(s.tasksA.taking(s.chat.id).map((t) => ({ ...t })), [{ station: "B", session: keyB }]);
  await s.close();
});

test("a station that is reached but does not answer is given it again, backing off, until it has it", async () => {
  const clock = testClock();
  const s = stations({ clock });
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  s.state.b = "silent";
  say(s.a.hub, s.chat.id, "ann@example.com", "did you get this?");
  await settle();
  const first = s.puts();
  await clock.adjust(999);
  await settle();
  assert.equal(s.puts(), first, "not before a second");
  await clock.adjust(1);
  await settle();
  assert.equal(s.puts(), first + 1, "again after 1 s");
  await clock.adjust(1999);
  await settle();
  assert.equal(s.puts(), first + 1, "then not before 2 s");
  await clock.adjust(1);
  await settle();
  assert.equal(s.puts(), first + 2, "again after 2 s");
  s.state.b = "here";
  await clock.adjust(4000);
  await settle();
  assert.ok(heard(s.b, keyB, "did you get this?"));
  const done = s.puts();
  await clock.adjust(120_000);
  await settle();
  assert.equal(s.puts(), done, "given: nothing more");
  await s.close();
});

test("a station that cannot run what it is invited to says why, and nothing is written into the Task", async () => {
  const s = stations();
  s.b.config = hubConfig({ ...s.b.raw, profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }] }, s.b.dir);
  const before = s.a.said(s.chat.id).length;
  await assert.rejects(s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude", model: "gpt-5.4-mini" }), /gpt-5\.4-mini/);
  await settle();
  assert.deepEqual(s.tasksA.taking(s.chat.id), []);
  assert.equal(s.a.said(s.chat.id).length, before);
  assert.equal(s.b.store.listSessions().length, 0);
  // Not reachable: the invite fails at once.
  s.state.b = "away";
  await assert.rejects(s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" }), Unreachable);
  await s.close();
});

test("a Task kept on Salix: invited and given over Salix's own connection, answered there, and told hello when it connects", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.begin();
  const asked: Json[] = [];
  let seq = 1;
  const salix = async (request: Json): Promise<Json> => {
    asked.push(request);
    if (request.method === "task.hello") return {};
    return { seq: ++seq };
  };
  tasks.attachHost("salix", salix);
  assert.deepEqual(asked, [{ method: "task.hello", tasks: [] }], "told it is here");
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  await settle();
  assert.ok(heard(b, session, "build it"));
  const thread = b.store.sessionThreads(session)[0]!.thread;
  await b.call(session, "chat_post", { to: threadAddress(thread.channel, thread.threadTs), text: "built" });
  assert.deepEqual(asked.at(-1), { method: "task.post", task: "cnv_1", session, text: "built", key: (asked.at(-1) as Json).key, declared: null });
  // Gone: a post fails, and the Session is told; connected again, it says hello.
  tasks.attachHost("salix", null);
  await assert.rejects(b.call(session, "chat_post", { to: threadAddress(thread.channel, thread.threadTs), text: "lost?" }), /not connected/);
  tasks.attachHost("salix", salix);
  assert.deepEqual(asked.at(-1), { method: "task.hello", tasks: [{ task: "cnv_1", fetched: 1 }] });
  assert.deepEqual(b.said(thread.id).map((m) => m.text), ["build it", "built"]);
  await b.close();
});

test("Task posts attach Markdown images with explicit files and preserve the Session's completion and milestones", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  const asked: Json[] = [];
  // Salix reads each named file, a part at a time, before it answers the post (SalixWeb.StationTasks).
  const read: Buffer[] = [];
  tasks.attachHost("salix", async (request: Json): Promise<Json> => {
    if (request.method === "task.hello") return {};
    asked.push(request);
    for (const file of request.files ?? []) {
      const parts: Buffer[] = [];
      for (let offset = 0; offset < file.size; ) {
        const part = await tasks.handle("salix", { method: "task.posted_file", task: request.task, session: request.session, key: request.key, index: file.index, offset });
        const data = Buffer.from(part.data, "base64");
        parts.push(data);
        offset += data.length;
      }
      read.push(Buffer.concat(parts));
    }
    return { seq: 2 };
  });
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "chart it", declared: null, at: 0 }], through: 1 });
  await settle();
  const thread = b.store.sessionThreads(session)[0]!.thread;
  const workspace = b.store.getSession(session)!.workspace;
  const chart = Buffer.alloc(FILE_PART * 2 + 10, 7);
  writeFileSync(join(workspace, "chart.png"), chart);
  writeFileSync(join(workspace, "notes.txt"), "notes\n");

  await b.call(session, "chat_post", {
    to: threadAddress(thread.channel, thread.threadTs),
    text: `the chart\n\n![Chart](${join(workspace, "chart.png")})`,
    files: ["notes.txt"],
    kind: "all_done",
    done: "Chart and notes delivered",
    milestones: ["Rendered the chart"],
  });
  const post = asked.at(-1)!;
  assert.deepEqual(post.files, [
    { index: 0, name: "notes.txt", size: 6 },
    { index: 1, name: "chart.png", size: chart.length },
  ]);
  assert.deepEqual(read, [Buffer.from("notes\n"), chart]);
  assert.equal(post.text, "the chart\n\n![Chart](chart%2Epng)");
  assert.equal(post.session, session);
  assert.equal(post.declared, "all_done");
  assert.deepEqual(post.milestones, ["Rendered the chart"]);
  // Answered, the post's files are no longer read from here.
  assert.deepEqual(await tasks.handle("salix", { method: "task.posted_file", task: "cnv_1", key: post.key, index: 0, offset: 0 }), { missing: "no such post" });
  await b.close();
});

test("a Task post with a missing Markdown image fails before publishing or ending the turn", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  const posts: Json[] = [];
  tasks.attachHost("salix", async (request: Json): Promise<Json> => {
    if (request.method === "task.hello") return {};
    posts.push(request);
    return { seq: 2 };
  });
  try {
    const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
    await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "show the chart", declared: null, at: 0 }], through: 1 });
    await settle();
    const thread = b.store.sessionThreads(session)[0]!.thread;
    const missing = join(b.store.getSession(session)!.workspace, "missing.png");
    const before = b.said(thread.id);
    await assert.rejects(b.call(session, "chat_post", {
      to: threadAddress(thread.channel, thread.threadTs),
      text: `![Chart](${missing})`,
      kind: "all_done",
      done: "Chart delivered",
    }), /correct the path/);
    assert.deepEqual(posts, []);
    assert.deepEqual(b.said(thread.id), before);
    b.claude.last().complete();
    await settle();
    assert.equal(b.store.lastTurn(session)!.declared, null);
  } finally {
    await b.close();
  }
});

test("Salix reads the execution history of the Session taking part in its Task, a page at a time, with its token use", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 2 }));
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  const history = (more: Json = {}) => tasks.handle("salix", { method: "task.history", task: "cnv_1", ...more });
  // Before its first turn there is none.
  assert.deepEqual(await history(), { start: 0, total: 0, entries: [], usage: { modelCalls: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0, model: null } });

  // Its runtime's transcript: a request, a command and its output, and the answer.
  const row = b.store.getSession(session)!;
  const home = b.hub.config().profiles.find((p) => p.id === row.profile)!.home;
  const id = "22222222-aaaa-bbbb-cccc-000000000002";
  b.store.setRuntimeSessionId(session, id);
  mkdirSync(join(home, "projects", "-w"), { recursive: true });
  const usage = { input_tokens: 100, cache_read_input_tokens: 40, output_tokens: 7 };
  const records = [
    { type: "user", timestamp: "2026-10-22T00:00:01.000Z", message: { content: "list the files" } },
    { type: "assistant", timestamp: "2026-10-22T00:00:02.000Z", message: { id: "m1", model: "claude-opus-5-5", usage, content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { command: "ls" } }] } },
    { type: "user", timestamp: "2026-10-22T00:00:03.000Z", message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: "README.md\nsrc", is_error: false }] } },
    { type: "assistant", timestamp: "2026-10-22T00:00:04.000Z", message: { id: "m2", model: "claude-opus-5-5", usage, content: [{ type: "text", text: "Two entries." }] } },
  ];
  writeFileSync(join(home, "projects", "-w", `${id}.jsonl`), records.map((r) => JSON.stringify(r)).join("\n") + "\n");

  const all = await history();
  assert.equal(all.total, 4);
  assert.deepEqual(all.entries.map((e: Json) => [e.kind, e.tool ?? null]), [["user", null], ["tool_call", "Bash"], ["tool_result", null], ["assistant", null]]);
  assert.equal(all.entries[1].callId, all.entries[2].callId);
  assert.deepEqual(all.usage, { modelCalls: 2, inputTokens: 280, cachedTokens: 80, outputTokens: 14, model: "claude-opus-5-5" });
  // The latest first: a page before an entry, as long as asked.
  assert.deepEqual(await history({ before: 3, limit: 2 }).then((p) => [p.start, p.entries.map((e: Json) => e.kind)]), [1, ["tool_call", "tool_result"]]);
  // Only a Salix host asks it.
  assert.deepEqual((await tasks.handle("B", { method: "task.history", task: "cnv_1" })).total, 0);
  await b.close();
});

test("a turn that fails in a Task kept on Salix says so in the Task", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  const posted: Json[] = [];
  tasks.attachHost("salix", async (request: Json): Promise<Json> => {
    if (request.method === "task.hello") return {};
    posted.push(request);
    return { seq: 1 + posted.length };
  });
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  await settle();
  b.claude.last().end({ kind: "failed", reason: "exited", message: "claude exited (1) during the turn: cannot run as root" });
  await settle();
  assert.equal(posted.length, 1, "the failed turn was not told in the Task");
  assert.equal(posted[0].session, session);
  assert.match(posted[0].text, /cannot run as root/);
  await b.close();
});

// The host asks where the Session of its Task stands (task.status): a read that starts no turn and changes nothing.
test("task.status says where the Session of a Task kept on Salix stands, and starts nothing", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 1 }));
  const status = (task: string, session?: string) => tasks.handle("salix", { method: "task.status", task, ...(session ? { session } : {}) });
  const given = (task: string) => tasks.handle("salix", { method: "task.put", task, messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  // No thread here of it.
  assert.deepEqual(await status("cnv_9"), { state: "gone", pending: 0, for_ms: null, last_failure: null });
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  // Invited and given nothing: idle, nothing pending. A Session of this station that takes no part in it: gone.
  let now = await status("cnv_1");
  assert.deepEqual([now.state, now.pending], ["idle", 0]);
  assert.equal((await status("cnv_1", "nobody")).state, "gone");
  // Given the Task: its turn runs, and asking starts no other.
  await given("cnv_1");
  await settle();
  now = await status("cnv_1", session);
  assert.deepEqual([now.state, now.pending, now.last_failure], ["running", 0, null]);
  assert.equal(typeof now.for_ms, "number");
  const prompts = b.claude.last().prompts.length;
  // The turn ends waiting on work it started.
  await b.call(session, "chat_state", { kind: "waiting", seconds: 60, for: "CI" });
  b.claude.last().complete();
  await settle();
  assert.equal((await status("cnv_1")).state, "waiting");
  // Given more: a turn runs again, and once it is all done, the Session is idle.
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 2, author: { kind: "person", id: "ann@example.com" }, text: "and test it", declared: null, at: 0 }], through: 2 });
  await settle();
  assert.equal((await status("cnv_1")).state, "running");
  await b.call(session, "chat_state", { kind: "final" });
  b.claude.last().complete();
  await settle();
  now = await status("cnv_1");
  assert.deepEqual([now.state, now.pending], ["idle", 0]);
  assert.equal(typeof now.for_ms, "number");
  assert.equal(b.claude.last().prompts.length, prompts + 1, "asked four times, prompted once more: by the put, not by the asking");

  // Another Task whose runtime does not start: what it was given stays pending, tried again; the host is told why.
  b.claude.open = async () => {
    throw new Error(`the runner did not start: ${"x".repeat(300)}`);
  };
  await tasks.handle("salix", { method: "task.invite", task: "cnv_2", start: { requester: "ann@example.com", runtime: "claude" } });
  await given("cnv_2");
  await settle();
  now = await status("cnv_2");
  assert.deepEqual([now.state, now.pending], ["cannot_start", 1]);
  assert.equal(typeof now.for_ms, "number");
  assert.ok(now.last_failure.startsWith("the runner did not start: xxx"), now.last_failure);
  assert.equal(Array.from(now.last_failure).length, 200, "at most 200 characters of why");
  await b.close();
});

// A Session whose runtime does not start says so in the Task once, marked so that the host can offer another model.
test("a turn that cannot start in a Task kept on Salix is told to Salix as such, once", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  const posted: Json[] = [];
  tasks.attachHost("salix", async (request: Json): Promise<Json> => {
    if (request.method === "task.hello") return {};
    posted.push(request);
    return { seq: 1 + posted.length };
  });
  b.claude.open = async () => {
    throw new Error("no account is chosen to run Claude Code here");
  };
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  await settle();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].session, session);
  assert.match(posted[0].text, /no account is chosen/);
  assert.deepEqual(posted[0].cannot_start, { error: "no account is chosen to run Claude Code here" });
  await b.close();
});

// The Task runs another model on the same station: a new Session takes the part of the old one in the same thread, and
// is handed what was not answered when the host gives the Task again; the old one hears nothing more of it.
test("invited again with replace, a new Session takes over a Task kept on Salix, in its thread", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 9 }));
  b.claude.open = async () => {
    throw new Error("no account");
  };
  const first = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  const given = { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 };
  await tasks.handle("salix", given);
  await settle();
  assert.equal(b.store.pendingMessages(first.session).length, 1, "pending for the Session that cannot start");
  // Invited again without replace: the same Session.
  assert.equal((await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "codex" } })).session, first.session);
  // With replace: a new Session in the same thread; the old one leaves it with what was pending.
  const second = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", replace: true, start: { requester: "ann@example.com", runtime: "codex" } });
  assert.notEqual(second.session, first.session);
  assert.equal(second.thread, first.thread);
  const thread = b.store.sessionThreads(second.session)[0]!.thread;
  assert.deepEqual(b.store.threadSessions(thread.id).map((m) => m.session), [second.session]);
  assert.equal(b.store.pendingMessages(first.session).length, 0);
  assert.equal(b.store.getSession(second.session)?.runtime, "codex");
  // The host gives the Task again from its start: the new Session is handed what was not answered, written once.
  await tasks.handle("salix", given);
  await settle();
  assert.ok(b.codex.last().prompts.some((p) => p.includes("build it")), "the new Session is handed what was not answered");
  assert.ok(!heard(b, first.session, "build it"), "the old Session is handed nothing");
  assert.equal(b.said(thread.id).filter((m) => m.text === "build it").length, 1, "written once");
  await b.close();
});

// A Session that runs a turn when the Task moves on is stopped: the old model does not go on beside the new one.
test("a Session running a turn of a Task kept on Salix is stopped when it is replaced, and when the Task leaves", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 9 }));
  const given = (task: string) =>
    tasks.handle("salix", { method: "task.put", task, messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await given("cnv_1");
  await settle();
  const running = b.claude.last();
  assert.equal(running.aborts, 0);
  await tasks.handle("salix", { method: "task.invite", task: "cnv_1", replace: true, start: { requester: "ann@example.com", runtime: "codex" } });
  await settle();
  assert.equal(running.aborts, 1, "the replaced Session's turn was stopped");

  await tasks.handle("salix", { method: "task.invite", task: "cnv_2", start: { requester: "ann@example.com", runtime: "claude" } });
  await given("cnv_2");
  await settle();
  const second = b.claude.last();
  assert.notEqual(second, running);
  await tasks.handle("salix", { method: "task.leave", task: "cnv_2" });
  await settle();
  assert.equal(second.aborts, 1, "a Session whose Task left was stopped");
  await b.close();
});

// A Task it left is named no more in its hello: it is told to leave once.
test("a station's hello names no Task its Sessions left", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 9 }));
  await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.invite", task: "cnv_2", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.leave", task: "cnv_1" });
  const hello: Json[] = [];
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (hello.push(request), {}));
  assert.deepEqual(hello.at(-1)?.tasks.map((t: Json) => t.task), ["cnv_2"]);
  await b.close();
});

// The Task runs elsewhere now: the Sessions here leave its thread with what was pending, and are given nothing more.
test("task.leave: the Sessions of a Task kept on Salix leave it, and a later invite takes up its thread", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (request: Json): Promise<Json> => (request.method === "task.hello" ? {} : { seq: 9 }));
  b.claude.open = async () => {
    throw new Error("no account");
  };
  const first = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "build it", declared: null, at: 0 }], through: 1 });
  await settle();
  assert.deepEqual(await tasks.handle("salix", { method: "task.leave", task: "cnv_1" }), {});
  assert.deepEqual(await tasks.handle("salix", { method: "task.leave", task: "cnv_9" }), {}, "nothing here to leave");
  assert.equal(b.store.pendingMessages(first.session).length, 0);
  const put = await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [], through: 1 });
  assert.equal(put.gone, true, "no Session here takes part any more");
  assert.equal((await tasks.handle("salix", { method: "task.status", task: "cnv_1" })).state, "gone");
  // The Task comes back here: a new Session takes up the thread it left, with what was said.
  const again = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  assert.notEqual(again.session, first.session);
  assert.equal(again.thread, first.thread);
  await b.close();
});

// Salix's Router reads a Task of this station's own over the station's connection to Salix, and writes in it: what it
// writes is given to the chat's Session, and said again with its key it is one Message.
test("Salix reads a Task of this station's own and writes in it once per key", async () => {
  const s = stations();
  const task = threadAddress(s.chat.channel, s.chat.threadTs);
  const read = await s.tasksA.handle("salix", { method: "task.read", task, after: 0, limit: 10 });
  assert.deepEqual(
    read.messages.map((m: Json) => [m.author_kind, m.author, m.text]),
    [["person", "ann@example.com", "build the release"]],
  );
  assert.equal(read.through, read.messages.at(-1).seq);
  const said = await s.tasksA.handle("salix", { method: "task.say", task, text: "ship it after the tests", key: "k1", requester: "Router" });
  assert.deepEqual(await s.tasksA.handle("salix", { method: "task.say", task, text: "ship it after the tests", key: "k1", requester: "Router" }), said);
  await settle();
  assert.equal(times(s.a, s.keyA, "ship it after the tests"), 1);
  const after = await s.tasksA.handle("salix", { method: "task.read", task, after: read.through });
  assert.deepEqual(after.messages.map((m: Json) => [m.author, m.text]), [["salix/Router", "ship it after the tests"]]);
  // The pages mark what the Router wrote as a request made elsewhere.
  const shown = entries(makeStore(s.a.store.db, s.a.config.dataDir), { email: "ann@example.com" } as Json, s.chat.id, {}).entries;
  assert.deepEqual(shown.map((e: Json) => [e.author, e.request]), [["ann@example.com", undefined], ["salix/Router", true]]);
  // Only the station's own chats: another station's Task, or one that is not here, is no Task of this station.
  await assert.rejects(s.tasksA.handle("salix", { method: "task.read", task: "EMBER/1.0" }), /no Task EMBER\/1.0 of this station/);
  await s.close();
});

// A Message's files: the Station taking part fetches them from the host (task.file) into its Session's uploads, and the
// Session hears the Message once they are there, in the Task's order.
test("a file sent in a Task reaches the Session of another station with its Message, and what comes after waits for it", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const dir = join(s.a.dir, "files");
  mkdirSync(dir, { recursive: true });
  const bytes = Buffer.alloc(FILE_PART * 2 + 17, 7);
  writeFileSync(join(dir, "demo.mp4"), bytes);
  // The fetch is cut off after its first part: B has the Message, but its Session does not hear it yet, nor what comes
  // after it.
  const handle = s.tasksA.handle.bind(s.tasksA);
  let cut = 0;
  s.tasksA.handle = async (peer, request) => {
    if (request.method === "task.file" && ++cut === 2) {
      s.state.b = "away";
      throw new Unreachable("peer unavailable");
    }
    return handle(peer, request);
  };
  say(s.a.hub, s.chat.id, "ann@example.com", "compress this", [{ name: "demo.mp4", path: join(dir, "demo.mp4"), size: bytes.length }]);
  await settle();
  say(s.a.hub, s.chat.id, "ann@example.com", "keep the resolution");
  await settle();
  assert.deepEqual(s.b.said(threadOf(s.b, keyB).id).map((m) => m.text), ["build the release"]);
  assert.ok(!heard(s.b, keyB, "compress this"));
  // Back: B goes on from what it had, and writes both, in order.
  s.state.b = "here";
  s.tasksB.connected();
  await settle();
  const thread = threadOf(s.b, keyB);
  const said = s.b.said(thread.id);
  assert.deepEqual(said.map((m) => m.text), ["build the release", "compress this", "keep the resolution"]);
  const [file] = said[1]!.attachments;
  assert.equal(file!.name, "demo.mp4");
  assert.ok(readFileSync(file!.path).equals(bytes), "the whole file, once");
  assert.ok(file!.path.startsWith(join(s.b.session(keyB).workspace, "uploads")));
  assert.ok(heard(s.b, keyB, file!.path), "the Session is told where it is");
  assert.equal(times(s.b, keyB, "keep the resolution"), 1);
  const parts = s.asked.filter(([from, , r]) => from === "B" && r.method === "task.file").map(([, , r]) => r.offset);
  assert.deepEqual([...new Set(parts)], [0, FILE_PART, FILE_PART * 2], "each part asked from what B had");
  await s.close();
});

for (const invalid of [
  { name: "bytes past the announced end", size: 10, responseSize: 10, responseBytes: 8 },
  { name: "a shorter size in a reply", size: 10, responseSize: 5, responseBytes: 2 },
  { name: "a chunk larger than FILE_PART", size: FILE_PART + 4, responseSize: FILE_PART + 4, responseBytes: FILE_PART + 1 },
]) {
  test(`a Task file rejects ${invalid.name} and resumes before the runtime hears its Message`, async (t) => {
    const clock = testClock();
    const b = new Rig({ clock: clock.clock });
    t.after(() => b.close());
    const tasks = new Tasks(b.hub, () => null);
    b.hub.setTasks(tasks);
    tasks.begin();
    const bytes = Buffer.alloc(invalid.size, 7);
    const offsets: number[] = [];
    let broken = true;
    tasks.attachHost("salix", async (request) => {
      if (request.method !== "task.file") return {};
      offsets.push(request.offset);
      if (broken && request.offset === 3) {
        return { size: invalid.responseSize, offset: request.offset, data: Buffer.alloc(invalid.responseBytes, 7).toString("base64") };
      }
      const end = request.offset === 0 ? 3 : request.offset + FILE_PART;
      return { size: bytes.length, offset: request.offset, data: bytes.subarray(request.offset, end).toString("base64") };
    });
    const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
    const thread = threadOf(b, session);
    await tasks.handle("salix", {
      method: "task.put", task: "cnv_1", through: 2,
      messages: [
        { seq: 1, id: "msg_1", author: { kind: "person", id: "ann" }, text: "Read these notes.", files: [{ index: 0, name: "notes.txt", size: bytes.length }] },
        { seq: 2, id: "msg_2", author: { kind: "person", id: "ann" }, text: "Then summarize them." },
      ],
    });
    await settle();
    assert.deepEqual(offsets, [0, 3]);
    assert.deepEqual(b.said(thread.id), [], "the Message and its follow-up wait for valid file data");
    assert.ok(!heard(b, session, "Read these notes."));
    const part = join(b.session(session).workspace, "uploads", `.part-task-${thread.id}-1-0`);
    assert.deepEqual(readFileSync(part), bytes.subarray(0, 3), "the invalid chunk never reaches disk");

    broken = false;
    await clock.adjust(1000);
    await settle();
    assert.equal(offsets[2], 3, "the retry keeps the validated prefix");
    const said = b.said(thread.id);
    assert.deepEqual(said.map((m) => m.text), ["Read these notes.", "Then summarize them."]);
    const [file] = said[0]!.attachments;
    assert.equal(file!.size, bytes.length);
    assert.deepEqual(readFileSync(file!.path), bytes);
    assert.ok(heard(b, session, file!.path));
    assert.equal(times(b, session, "Then summarize them."), 1);
  });
}

for (const cached of ["partial", "complete"] as const) {
  test(`a Task file repairs a ${cached} download with the wrong size before delivery`, async (t) => {
    const b = new Rig();
    t.after(() => b.close());
    const tasks = new Tasks(b.hub, () => null);
    b.hub.setTasks(tasks);
    tasks.begin();
    const bytes = Buffer.from("the complete notes");
    const offsets: number[] = [];
    tasks.attachHost("salix", async (request) => {
      if (request.method !== "task.file") return {};
      offsets.push(request.offset);
      return { size: bytes.length, offset: request.offset, data: bytes.subarray(request.offset).toString("base64") };
    });
    const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
    const thread = threadOf(b, session);
    const dir = join(b.session(session).workspace, "uploads");
    mkdirSync(dir, { recursive: true });
    const path = join(dir, "task-1-0-notes.txt");
    writeFileSync(cached === "complete" ? path : join(dir, `.part-task-${thread.id}-1-0`), cached === "complete" ? bytes.subarray(0, 3) : Buffer.alloc(bytes.length + 1));
    const message = { seq: 1, id: "msg_1", author: { kind: "person", id: "ann" }, text: "Read these notes.", files: [{ index: 0, name: "notes.txt", size: bytes.length }] };
    await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [message], through: 1 });
    await settle();
    assert.deepEqual(offsets, [0], "a cached file with the wrong size is fetched again");
    assert.deepEqual(readFileSync(path), bytes);
    assert.deepEqual(b.said(thread.id)[0]!.attachments, [{ name: "notes.txt", path, size: bytes.length }]);
    assert.ok(heard(b, session, path));

    if (cached === "complete") {
      // A crash after delivery can leave the arrival queued. Do not replace the runtime's later edits.
      b.store.db.prepare("INSERT INTO task_arrivals (thread, seq, message) VALUES (?, ?, ?)").run(thread.id, message.seq, JSON.stringify(message));
      writeFileSync(path, "edited by the runtime");
      tasks.connected();
      await settle();
      assert.deepEqual(offsets, [0]);
      assert.equal(readFileSync(path, "utf8"), "edited by the runtime");
      assert.equal(b.said(thread.id).length, 1);
    }
  });
}

test("milestones alone behind a Message waiting for its file are written after it, and handed to no Session", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const dir = join(s.a.dir, "files");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "plan.txt"), "the plan");
  // B cannot fetch the file yet: what comes after its Message waits for it.
  const handle = s.tasksA.handle.bind(s.tasksA);
  let away = true;
  s.tasksA.handle = async (peer, request) => {
    if (request.method === "task.file" && away) throw new Unreachable("peer unavailable");
    return handle(peer, request);
  };
  say(s.a.hub, s.chat.id, "ann@example.com", "follow this", [{ name: "plan.txt", path: join(dir, "plan.txt"), size: 8 }]);
  await settle();
  await s.a.call(s.keyA, "chat_post", { to: threadAddress(s.chat.channel, s.chat.threadTs), milestones: ["Read the plan"] });
  await settle();
  const thread = threadOf(s.b, keyB);
  assert.deepEqual(s.b.store.entriesAfter(thread.id, 0).map((e) => e.kind), ["message"]);
  away = false;
  s.tasksB.connected();
  await settle();
  const written = s.b.store.entriesAfter(thread.id, 0).slice(1);
  assert.deepEqual(written.map((e) => [e.kind, e.text, e.attachments.length, e.milestones]), [
    ["message", "follow this", 1, undefined],
    ["milestone", null, 0, ["Read the plan"]],
  ]);
  const handed = (s.b.store.db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ? AND n = ?").get(thread.id, written[1]!.n) as Json).c;
  assert.equal(handed, 0);
  await s.close();
});

test("a file the host no longer has is named in its Message, which is handed over without it", async () => {
  const s = stations();
  const keyB = await s.tasksA.invite(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  say(s.a.hub, s.chat.id, "ann@example.com", "look at this", [{ name: "gone.png", path: join(s.a.dir, "nowhere.png"), size: 10 }]);
  await settle();
  const said = s.b.said(threadOf(s.b, keyB).id).at(-1)!;
  assert.match(said.text, /^look at this\n\n\[.*gone\.png.*no longer on its station\]$/);
  assert.deepEqual(said.attachments, []);
  assert.ok(heard(s.b, keyB, said.text));
  await s.close();
});

test("a person's image and file reach the runtime from a Salix Task before it hears the Message", async () => {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.begin();
  const files = [
    { name: "screen.png", bytes: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64") },
    { name: "notes.txt", bytes: Buffer.from("notes for the screenshot") },
  ];
  const asked: Json[] = [];
  const salix = async (request: Json): Promise<Json> => {
    asked.push(request);
    if (request.method === "task.hello") return {};
    if (request.method === "task.file") {
      const file = files[request.index];
      if (request.id !== "msg_1" || !file) return { missing: "no such file" };
      return { name: file.name, size: file.bytes.length, offset: request.offset, data: file.bytes.subarray(request.offset, request.offset + 5).toString("base64") };
    }
    return { seq: 9 };
  };
  tasks.attachHost("salix", salix);
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  const message = { seq: 1, id: "msg_1", author: { kind: "person", id: "ann" }, text: "Review these attachments.", declared: null, at: 0, files: files.map((file, index) => ({ index, name: file.name, size: file.bytes.length })) };
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [message], through: 1 });
  await settle();
  const thread = b.store.sessionThreads(session)[0]!.thread;
  const attachments = b.said(thread.id)[0]!.attachments;
  assert.equal(attachments.length, 2);
  for (const [index, file] of attachments.entries()) {
    assert.ok(readFileSync(file.path).equals(files[index]!.bytes));
    assert.ok(heard(b, session, file.path));
  }
  assert.deepEqual(
    asked.filter((r) => r.method === "task.file").map((r) => [r.task, r.session, r.seq, r.id, r.index, r.offset]),
    files.flatMap((file, index) => Array.from({ length: Math.ceil(file.bytes.length / 5) }, (_, part) => ["cnv_1", session, 1, "msg_1", index, part * 5])),
  );
  // Given again: written once, fetched no more.
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [message], through: 1 });
  await settle();
  assert.equal(b.said(thread.id).length, 1);
  assert.equal(asked.filter((r) => r.method === "task.file").length, files.reduce((n, file) => n + Math.ceil(file.bytes.length / 5), 0));
  await b.close();
});

test("a Task here runs on another station and back: there a Session takes it up, here its own session hands it over, then takes it up afresh", async () => {
  const s = stations();
  const to = threadAddress(s.chat.channel, s.chat.threadTs);
  await settle();
  // A's own session answers the first request and ends its turn.
  await s.a.call(s.keyA, "chat_post", { to, text: "building it", kind: "all_done", done: "built 1.2.3" });
  s.a.claude.last().complete();
  await settle();
  // Asked of A's own session while it works on: not answered yet.
  say(s.a.hub, s.chat.id, "ann@example.com", "and the release notes");
  await settle();

  // To B: its Session is given the Task from its start, and handed what A's own session had not answered.
  s.b.edit((raw) => {
    raw.profiles[0].models = ["opus"];
  });
  const keyB = await s.tasksA.moveTo(s.chat.id, "B", { requester: "ann@example.com", title: "release", runtime: "claude", model: "opus" });
  await settle();
  // The turn A's own session was in is stopped.
  const working = s.a.claude.last();
  assert.equal(working.aborts, 1);
  working.end({ kind: "aborted" });
  await settle();
  const thread = threadOf(s.b, keyB);
  assert.deepEqual(
    s.b.said(thread.id).map((m) => m.text),
    ["build the release", "building it", "and the release notes"],
  );
  assert.ok(!heard(s.b, keyB, "build the release"));
  assert.ok(heard(s.b, keyB, "and the release notes"));
  assert.equal(s.a.store.runsOn(s.chat.id), "B");
  // What is said from then on goes to B's Session alone; A's own session may no longer answer in it.
  say(s.a.hub, s.chat.id, "ann@example.com", "now publish it");
  await settle();
  assert.ok(heard(s.b, keyB, "now publish it"));
  assert.ok(!heard(s.a, s.keyA, "now publish it"));
  assert.match(await s.a.refused(s.keyA, "chat_post", { to, text: "me too" }), /runs on another station/);
  // Where it runs, as the Task's page and its index say: B, with what B's Session was started with.
  const view = threadView(makeStore(s.a.store.db, s.a.config.dataDir), { email: "ann@example.com" } as Json, String(s.chat.id), "en");
  assert.deepEqual(view.runsOn, { station: "B", session: keyB, runtime: "claude", model: "opus" });
  const row = () => JSON.parse(s.a.store.taskIndexSince(0, 100).find((r) => r.thread === s.chat.id)!.json);
  assert.deepEqual([row().runtime, row().model, row().status], ["claude", "opus", "in_progress"]);
  await s.b.call(keyB, "chat_post", { to: threadAddress(thread.channel, thread.threadTs), text: "published", kind: "all_done", done: "published 1.2.3" });
  await settle();
  assert.equal(row().status, "needs_review");

  // Back here: B leaves it, and A's own session takes it up afresh, handed what B had not answered.
  say(s.a.hub, s.chat.id, "ann@example.com", "one more thing");
  await settle();
  const ran = s.a.claude.count();
  await s.tasksA.moveHome(s.chat.id);
  await settle();
  assert.equal(s.a.store.runsOn(s.chat.id), null);
  assert.deepEqual(s.b.store.threadSessions(thread.id), [], "B's Session left the Task");
  assert.equal(s.a.claude.count(), ran + 1);
  const afresh = s.a.claude.last();
  assert.equal(afresh.options.resume, undefined);
  assert.ok(afresh.prompts[0]!.includes("This is a new conversation"), afresh.prompts[0]);
  assert.ok(heard(s.a, s.keyA, "one more thing"));
  assert.ok(!heard(s.a, s.keyA, "now publish it"));
  say(s.a.hub, s.chat.id, "ann@example.com", "thanks");
  await settle();
  assert.ok(!heard(s.b, keyB, "thanks"));
  await s.close();
});

test("a Task here that cannot run on another station runs as it did", async () => {
  const s = stations();
  await settle();
  s.state.b = "away";
  await assert.rejects(s.tasksA.moveTo(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" }));
  assert.equal(s.a.store.runsOn(s.chat.id), null);
  assert.deepEqual(s.tasksA.taking(s.chat.id), []);
  say(s.a.hub, s.chat.id, "ann@example.com", "still here?");
  await settle();
  assert.ok(heard(s.a, s.keyA, "still here?"));
  await s.close();
});

test("a station that ran a Task here while away is told to leave it when it says hello", async () => {
  const s = stations();
  await settle();
  const keyB = await s.tasksA.moveTo(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  s.state.b = "away";
  await s.tasksA.moveHome(s.chat.id);
  await settle();
  const thread = threadOf(s.b, keyB);
  assert.equal(s.b.store.threadSessions(thread.id).length, 1, "not told yet");
  s.state.b = "here";
  s.tasksB.connected();
  await settle();
  assert.deepEqual(s.b.store.threadSessions(thread.id), []);
  await s.close();
});

test("a Session running a Task of another station posts files: given first a part at a time, whole into the Task's chat", async () => {
  const s = stations();
  await settle();
  const keyB = await s.tasksA.moveTo(s.chat.id, "B", { requester: "ann@example.com", runtime: "claude" });
  await settle();
  const thread = threadOf(s.b, keyB);
  const workspace = s.b.store.getSession(keyB)!.workspace;
  // Larger than a part: given in three, and once more from where A has it when an answer is lost.
  const big = Buffer.alloc(FILE_PART * 2 + 10, 7);
  writeFileSync(join(workspace, "build.log"), big);
  writeFileSync(join(workspace, "notes.txt"), "done");
  let lost = 1;
  s.state.lose = (from, request) => from === "B" && request.method === "task.post_file" && request.offset === FILE_PART && lost-- > 0;
  await s.b.call(keyB, "chat_post", { to: threadAddress(thread.channel, thread.threadTs), text: "logs attached", files: ["build.log", "notes.txt"] });
  await settle();
  const atA = s.a.said(s.chat.id).at(-1)!;
  assert.deepEqual([atA.author, atA.text, atA.attachments.map((f) => [f.name, f.size])], [`B/${keyB}`, "logs attached", [["build.log", big.length], ["notes.txt", 4]]]);
  assert.deepEqual(readFileSync(atA.attachments[0]!.path), big);
  assert.equal(readFileSync(atA.attachments[1]!.path, "utf8"), "done");
  const given = s.asked.filter(([from, , r]) => from === "B" && r.method === "task.post_file");
  assert.equal(given.length, 3 + 1 + 1, "three parts, one given again, and the small file");
  // A post naming a file not given whole first is refused.
  await assert.rejects(
    s.tasksA.handle("B", { method: "task.post", task: threadAddress(s.chat.channel, s.chat.threadTs), session: keyB, text: "more", key: "k-none", files: [{ index: 0, name: "x.bin", size: 5 }] }),
    /not given whole/,
  );
  await s.close();
});
