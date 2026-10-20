// Tasks between stations (src/tasks/tasks.ts): a Task kept on station A, a Session of station B taking part in it.
// The two hubs' requests go to each other directly, as the station transport would carry them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { threadAddress } from "../src/agents/instructions.ts";
import { Unreachable } from "../src/jobs/remote.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { type Call, PUT_LIMIT, TASK_SURFACE, Tasks } from "../src/tasks/tasks.ts";
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
  // How B is now: here, away (cannot be reached), or reached but not answering.
  const state = { b: "here" as "here" | "away" | "silent" };
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
      return JSON.parse(JSON.stringify(await there.handle(from, JSON.parse(JSON.stringify(request)))));
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
  // Only the station's own chats: another station's Task, or one that is not here, is no Task of this station.
  await assert.rejects(s.tasksA.handle("salix", { method: "task.read", task: "EMBER/1.0" }), /no Task EMBER\/1.0 of this station/);
  await s.close();
});
