// The hub (src/sessions/hub.ts): routing, sessions, turns, nudges, waits, stops, sign-in retries, hold and release,
// recover and handover, eviction, single-session connects, the station's own chat. Ported from
// the Rust station's hub/tests.rs, on a real Store, a fake chat platform and fake runtimes.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { GO_ON_AFTER_AUTH, GO_ON_AFTER_SPENT, NUDGE } from "../src/agents/instructions.ts";
import { latest } from "../src/agents/migrations.ts";
import { classifyResult } from "../src/agents/claude.ts";
import { stationIdle } from "../src/connector/service.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { addToThread, autoArchive, archive, archiveChat, bindSingle, configure, deleteSession, newSession, openChat, say as sayIn } from "../src/sessions/lifecycle.ts";
import { AUTO, MANUAL } from "../src/store/store.ts";
import { FakeDriver, Rig, matches, message, reply, say, settle, testClock } from "./hub-fakes.ts";

const chat = (runtime: "claude" | "codex" = "claude") => ({ runtime, createdBy: "local" });

test("a new session first says where it can be followed, multi-session connects only", async () => {
  const r = new Rig({ link: true });
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  assert.equal(r.chat.posts.length, 1);
  assert.equal(r.chat.posts[0]![1], `<https://ember.test/o/ws/st/cl%3AC1%3A${m.threadTs}|在 still.fail 里查看这个会话>`);
  assert.deepEqual(r.chat.posts[0]![0], { channel: "C1", threadTs: m.threadTs });
  // Its next message is the same session: nothing more.
  await r.accept({ ...say("<@UBOT> and the tests"), threadTs: m.threadTs });
  await settle();
  assert.equal(r.chat.texts().length, 1);
  // A single-session connect has one session for everything: no link per thread.
  await r.accept(say("<@UBOT> hi"), "team");
  await settle();
  assert.deepEqual(r.teamChat.texts(), []);
  await r.close();
});

test("a mention starts a session and prompts the runtime with the message", async () => {
  const r = new Rig();
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  const session = r.claude.last();
  assert.equal(session.prompts.length, 1);
  // What the agent is called there comes with the message (the connect's bot and its mention).
  const expected = `<message via="slack" connect="cl" you="ember (<@UBOT>)" thread="C1/${m.ts}" from="U1" ts="${m.ts}">\n<@UBOT> fix the build\n</message>`;
  assert.ok(session.prompts[0]!.includes(expected), session.prompts[0]);
  assert.equal(r.session(sessionKey("cl", "C1", m.threadTs)).runtimeSessionId, session.sessionId);
  assert.ok(session.options.cwd.endsWith("workspace"));
  await r.close();
});

test("thread chatter without a session is ignored", async () => {
  const r = new Rig();
  await r.accept(say("just talking", { addressed: false }));
  await settle();
  assert.equal(r.claude.count(), 0);
  await r.close();
});

test("a mention inside an existing thread records what was said before and tells the agent about it", async () => {
  const r = new Rig();
  const earlier = (ts: string, user: string, text: string) => ({ ts, user, text, fromBot: false });
  r.chat.earlier.set("1.000001", [earlier("1.000001", "U2", "the build is red"), earlier("3.000001", "U3", "since this morning")]);
  await r.accept(message({ threadTs: "1.000001", ts: "5.000001" }));
  await settle();
  const prompt = r.claude.last().prompts[0]!;
  assert.ok(prompt.includes("Thread C1/1.000001 had messages before you were brought in"), prompt);
  assert.ok(!prompt.includes("the build is red"), "earlier messages are recorded, not delivered");
  const thread = r.thread("C1", "1.000001");
  assert.deepEqual(
    r.said(thread.id).map((m) => m.ts),
    ["1.000001", "3.000001", "5.000001"],
  );
  const history = await r.call(sessionKey("cl", "C1", "1.000001"), "chat_history", { to: "C1/1.000001", before: "5.000001" });
  assert.ok(history.includes('from="U2" ts="1.000001">\nthe build is red'), history);
  assert.ok(!history.includes("hello"));
  await r.close();
});

test("files shared in Slack are fetched into the session's uploads and given to the agent, once", async () => {
  const r = new Rig();
  r.chat.shared.set("F1", "error overlay");
  const file = (id: string, name: string) => ({ id, name, size: 13, url: `https://files.slack.com/${id}` });
  const m = say("<@UBOT> 看看", { files: [file("F1", "shot.png"), file("F2", "log.txt")] });
  await r.accept(m);
  await r.accept(m);
  await settle();
  assert.deepEqual(r.chat.downloads, ["F1", "F2"], "a message sent again is not fetched again");
  const [said] = r.said(r.thread("C1", m.threadTs).id);
  assert.equal(said!.text, "<@UBOT> 看看\n\n[文件 log.txt 没拿到：missing_scope]");
  assert.equal(said!.attachments.length, 1);
  const [shot] = said!.attachments;
  assert.equal(shot!.name, "shot.png");
  assert.equal(dirname(shot!.path), join(r.session(sessionKey("cl", "C1", m.threadTs)).workspace, "uploads"));
  assert.equal(readFileSync(shot!.path, "utf8"), "error overlay");
  const prompt = r.claude.last().prompts[0]!;
  assert.ok(prompt.includes(`Attached files:\n- ${shot!.path} (shot.png, 13 bytes)`), prompt);
  assert.ok(prompt.includes("log.txt 没拿到"), prompt);
  await r.close();
});

test("files shared before the station joined a thread are fetched with what was said", async () => {
  const r = new Rig();
  r.chat.shared.set("F3", "trace");
  r.chat.earlier.set("1.000002", [{ ts: "1.000002", user: "U2", text: "", fromBot: false, files: [{ id: "F3", name: "trace.txt", size: 5, url: "https://files.slack.com/F3" }] }]);
  await r.accept(message({ threadTs: "1.000002", ts: "5.000002" }));
  await settle();
  const [first] = r.said(r.thread("C1", "1.000002").id);
  assert.equal(first!.attachments[0]!.name, "trace.txt");
  assert.equal(readFileSync(first!.attachments[0]!.path, "utf8"), "trace");
  await r.close();
});

test("a message during a running turn is steered into it", async () => {
  const r = new Rig();
  const first = message();
  await r.accept(first);
  await settle();
  await r.accept(reply(first, "9999.1", "also check tests"));
  await settle();
  assert.equal(r.claude.last().prompts.length, 1);
  assert.ok(r.claude.last().steers[0]!.includes("also check tests"));
  await r.close();
});

test("a message during a running turn moves what it waits on to the background, unless its profile says not", async () => {
  const r = new Rig();
  const first = message();
  await r.accept(first);
  await settle();
  await r.accept(reply(first, "9999.1", "also check tests"));
  await settle();
  const session = r.claude.last();
  assert.equal(session.backgrounds, 1);
  r.edit((c) => c.profiles.forEach((p: any) => (p.background_on_message = false)));
  await r.accept(reply(first, "9999.2", "and lint"));
  await settle();
  assert.equal(session.steers.length, 2);
  assert.equal(session.backgrounds, 1, "off: the message waits for what the turn waits on");
  await r.close();
});

test("the same message delivered twice is handled once", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await r.accept(m);
  await settle();
  assert.equal(r.claude.last().prompts.length, 1);
  await r.close();
});

test("a turn ending without a state is nudged, then reported after max nudges", async () => {
  const r = new Rig({ maxNudges: 1 });
  await r.accept(message());
  await settle();
  r.claude.last().complete();
  await settle();
  const prompts = r.claude.last().prompts;
  assert.equal(prompts.length, 2);
  assert.ok(prompts[1]!.includes("ended without a state"));
  r.claude.last().complete();
  await settle();
  assert.equal(r.claude.last().prompts.length, 2);
  assert.ok(r.chat.lastText().includes("没有给出结果"));
  await r.close();
});

test("a turn ending waiting is not nudged nor evicted, and is asked again when the wait is over", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig({ maxWarmClaude: 0, warmMinutes: 0 });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const said = await r.call(key, "chat_state", { kind: "waiting", seconds: 1, for: "CI 跑完" });
  assert.ok(said.includes("in 10 seconds"), `at least 10: ${said}`);
  r.claude.last().complete();
  await settle();
  const last = r.store.sessionStats(null).get(key)!.lastTurn!;
  assert.deepEqual([last.declared, last.waitFor], ["waiting", "CI 跑完"], "what it waits for is kept with the turn");
  assert.equal(r.claude.last().prompts.length, 1, "not nudged");
  assert.ok(!r.claude.last().disposed, "its background work may run in its process");
  assert.deepEqual(r.chat.texts(), []);
  t.mock.timers.tick(11_000);
  await settle();
  const prompts = r.claude.last().prompts;
  assert.equal(prompts.length, 2);
  assert.ok(prompts[1]!.includes("waiting on work you started (10 seconds)"), prompts[1]);
  assert.deepEqual(
    r.store.listTurns(key).flatMap((t) => t.summary.declared ?? []),
    ["waiting"],
  );
  await r.close();
});

test("a turn that did not start: the thread is told why once, the message stays pending and the station not idle, and it is given again (1 s, 2 s, 4 s…) until a turn starts", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  // The runtime does not start (its runner refuses, say), three times.
  let failing = 3;
  let tries = 0;
  const open = r.claude.open.bind(r.claude);
  r.claude.open = async (options, events) => {
    tries++;
    if (failing-- > 0) throw new Error("the runner did not start: stillfail-runner: cc is already kept by a runner");
    return open(options, events);
  };
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const notices = () => r.chat.texts().filter((t) => t.includes("无法启动 agent"));
  assert.deepEqual(notices(), ["⚠️ 无法启动 agent：the runner did not start: stillfail-runner: cc is already kept by a runner"]);
  assert.equal(tries, 1);
  assert.equal(r.store.pendingMessages(key).length, 1, "the message is still to be given");
  assert.ok(!stationIdle(r.store), "a station that holds a message not given is not idle");

  // Given again by itself: after 1 s, then 2 s more; not before.
  for (const [wait, tried] of [[1000, 2], [2000, 3]] as const) {
    await time.adjust(wait - 1);
    await settle();
    assert.equal(tries, tried - 1, `tried again before ${wait} ms were over`);
    await time.adjust(1);
    await settle();
    assert.equal(tries, tried);
    assert.equal(r.store.pendingMessages(key).length, 1);
    assert.ok(!stationIdle(r.store));
  }
  assert.equal(notices().length, 1, "the thread is told once, not at every try");

  // The runtime starts at the next try, 4 s on: the turn runs with the message, and nothing more is tried.
  await time.adjust(4000);
  await settle();
  assert.equal(tries, 4);
  assert.ok(r.claude.last().prompts[0]!.includes("fix the build"));
  assert.deepEqual(r.store.pendingMessages(key), []);
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  r.claude.last().complete();
  await settle();
  assert.ok(stationIdle(r.store));
  await time.adjust(120_000);
  await settle();
  assert.equal(tries, 4);
  assert.equal(notices().length, 1);
  await r.close();
});

test("a message that comes while a turn that did not start waits to be tried again is tried at once, and its failure told", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  let failing = true;
  const open = r.claude.open.bind(r.claude);
  r.claude.open = async (options, events) => {
    if (failing) throw new Error("no runtime");
    return open(options, events);
  };
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  await r.accept(reply(m, "2000.000100", "<@UBOT> still there?", { addressed: true }));
  await settle();
  assert.equal(r.chat.texts().filter((t) => t.includes("无法启动 agent")).length, 2, "whoever wrote is told it did not start");
  failing = false;
  await r.accept(reply(m, "2001.000100", "<@UBOT> and now?", { addressed: true }));
  await settle();
  const prompt = r.claude.last().prompts[0]!;
  assert.ok(matches(prompt, ["fix the build", "still there?", "and now?"]), prompt);
  await r.close();
});

const watchJob = (session: string) => ({
  id: "job_w", sessionKey: session, name: "盯 CI", command: "sleep 600", cwd: "/", port: null, token: "tw", state: "running",
  pgid: null, exitCode: null, startedAt: Date.now(), endedAt: null, restarts: 0, log: "/dev/null", watch: true,
});

test("a wait does not run out while a watch of its session runs", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  r.store.insertJob(watchJob(key));
  await r.call(key, "chat_state", { kind: "waiting", seconds: 10, for: "CI 跑完" });
  r.claude.last().complete();
  await settle();
  for (let i = 0; i < 4; i++) {
    t.mock.timers.tick(10_000);
    await settle();
  }
  assert.equal(r.claude.last().prompts.length, 1, "the watch brings it back, not the clock");
  // The watch over, the wait runs out as any other.
  r.store.jobEnded("job_w", "stopped", null);
  t.mock.timers.tick(11_000);
  await settle();
  assert.equal(r.claude.last().prompts.length, 2);
  await r.close();
});

test("a turn that starts before the wait is over ends it", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "CI 跑完" });
  r.claude.last().complete();
  await settle();
  await r.accept(reply(m, "9999.1", "any news?"));
  await settle();
  await r.call(key, "chat_state", { kind: "final" });
  r.claude.last().complete();
  t.mock.timers.tick(120_000);
  await settle();
  assert.equal(r.claude.last().prompts.length, 2, "no word when the old wait's time comes");
  assert.ok((await r.refused(key, "chat_state", { kind: "waiting" })).includes("seconds is required"));
  assert.ok((await r.refused(key, "chat_state", { kind: "waiting", seconds: 60 })).includes("for is required"));
  await r.close();
});

test("slack edits are appended to the thread as entries of their own", async () => {
  const r = new Rig();
  const m = say("<@UBOT> typo");
  await r.accept(m);
  const thread = r.thread("C1", m.threadTs);
  const before = r.store.lastEntry(thread.id);
  const edit = { type: "changed" as const, channel: "C1", threadTs: m.threadTs, ts: m.ts, text: "<@UBOT> fixed" };
  await r.hub.receive("cl", edit);
  await r.hub.receive("cl", edit); // Slack repeats roots when replies come
  const entries = r.store.entriesAfter(thread.id, before);
  assert.deepEqual([entries[0]!.kind, entries[0]!.target, entries[0]!.text], ["edit", before, "<@UBOT> fixed"]);
  assert.equal(r.store.lastEntry(thread.id), before + 1);
  await settle();
  await r.close();
});

test("stop aborts the running turn and confirms once it ends", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  await r.accept(reply(m, "9999.2", "<@UBOT> -stop", { addressed: true }));
  await settle();
  const session = r.claude.last();
  assert.equal(session.aborts, 1);
  assert.deepEqual(session.steers, [], "-stop is not forwarded to the agent");
  session.end({ kind: "aborted" });
  await settle();
  assert.equal(r.chat.lastText(), "已停止当前任务");
  assert.equal(session.prompts.length, 1, "no nudge after a stop");
  await r.close();
});

test("stop while waiting ends the wait and its process", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_state", { kind: "waiting", seconds: 10, for: "任务跑完" });
  r.claude.last().complete();
  await settle();
  await r.accept(reply(m, "9999.2", "<@UBOT> -stop", { addressed: true }));
  await settle();
  assert.ok(r.claude.last().disposed, "the background work in its process ends with it");
  assert.equal(r.chat.lastText(), "已停止当前任务");
  const last = r.store.lastTurn(key)!;
  assert.deepEqual([last.outcome, last.declared, last.waitSeconds], ["aborted", null, null], "no longer shown running");
  t.mock.timers.tick(30_000);
  await settle();
  assert.equal(r.claude.last().prompts.length, 1, "not asked again when the wait would have been over");
  await r.close();
});

test("stop while waiting ends the jobs that would bring it back, but not its services", async () => {
  const r = new Rig();
  const stopped: string[] = [];
  r.hub.setJobs({
    stop: async (id) => {
      stopped.push(id);
      r.store.jobEnded(id, "stopped", null);
      return r.store.getJob(id)!;
    },
  });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const job = (id: string, port: number | null, watch: boolean) => r.store.insertJob({ ...watchJob(key), id, token: `t${id}`, port, watch });
  job("build", null, false);
  job("watch", null, true);
  job("page", 47123, false);
  await r.call(key, "chat_state", { kind: "waiting", seconds: 600, for: "任务跑完" });
  r.claude.last().complete();
  await settle();
  await r.hub.stop(key);
  await settle();
  const state = (id: string) => r.store.getJob(id)!.state;
  assert.deepEqual([state("build"), state("watch"), state("page")], ["stopped", "stopped", "running"]);
  assert.equal(r.chat.lastText(), "已停止当前任务");
  await r.close();
});

test("claude auth retries once, then reports the profile and does not loop", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const first = r.claude.last();
  first.end({ kind: "failed", reason: "auth", message: "401 Missing API key" });
  await settle();
  const retry = r.claude.last();
  assert.ok(first.disposed);
  assert.equal(r.claude.count(), 2);
  assert.equal(retry.options.resume, first.sessionId);
  assert.deepEqual(retry.prompts, [GO_ON_AFTER_AUTH]);
  assert.ok(!r.chat.texts().some((t) => t.includes("认证失败")));
  retry.end({ kind: "failed", reason: "auth", message: "401 Missing API key" });
  await settle();
  assert.equal(r.claude.count(), 2, "a persistent auth failure must stop, not loop");
  assert.ok(matches(r.chat.lastText(), ["认证失败", "401 Missing API key"]));
  assert.equal(r.claude.last().prompts.length, 1);
  // The notice says whose sign-in failed, for the clients to link that profile's page; another failure is no profile's.
  const thread = r.thread("C1", m.threadTs);
  const last = () => r.store.entriesBefore(thread.id, null, 1).pop()!;
  assert.deepEqual([last().authorKind, last().profile], ["ember", "cc"]);
  await r.accept(reply(m, "9999.2", "<@UBOT> again", { addressed: true }));
  await settle();
  r.claude.last().end({ kind: "failed", reason: "exited", message: "exit 1" });
  await settle();
  assert.ok(matches(r.chat.lastText(), ["意外退出"]));
  assert.equal(last().profile, null);
  await r.close();
});

test("claude auth recovers without replaying input, and a later turn can recover again", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = r.claude.last().options.route;
  for (const expected of [2, 3]) {
    r.claude.last().end({ kind: "failed", reason: "auth", message: "401 expired token" });
    await settle();
    assert.equal(r.claude.count(), expected);
    assert.deepEqual(r.claude.last().prompts, [GO_ON_AFTER_AUTH]);
    await r.call(key, "chat_state", { kind: "all_done", done: "测试任务已完成，没有剩余工作" });
    r.claude.last().complete();
    await settle();
    assert.ok(!r.chat.texts().some((t) => t.includes("认证失败")));
    if (expected === 2) {
      await r.accept(reply(m, "9999.2", "<@UBOT> next task", { addressed: true }));
      await settle();
    }
  }
  await r.close();
});

test("claude auth does not restart stopped, held or declared work", async () => {
  for (const mode of ["stop", "hold", "declared"]) {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    if (mode === "stop") await r.accept(reply(m, "9999.2", "<@UBOT> -stop", { addressed: true }));
    else if (mode === "hold") r.hub.hold("drain");
    else await r.call(r.claude.last().options.route, "chat_state", { kind: "all_done", done: "测试任务已完成，没有剩余工作" });
    await settle();
    r.claude.last().end({ kind: "failed", reason: "auth", message: "401" });
    await settle();
    assert.equal(r.claude.count(), 1, mode);
    await r.close();
  }
});

test("claude auth's retry budget and whom the turn is for survive a handover", async () => {
  const r = new Rig();
  await r.accept(message());
  await settle();
  r.claude.last().end({ kind: "failed", reason: "auth", message: "401" });
  await settle();
  const handed = await r.hub.handOver();
  const turn = handed.sessions[0]!.turn!;
  assert.ok(turn.authRetried);
  assert.ok(turn.by.person !== null);
  assert.ok(turn.by.thread !== null);
  await r.close();
});

test("messages that arrive while a turn cannot take them go in the next turn", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const session = r.claude.last();
  session.unsteerable = true;
  await r.accept(reply(m, "9999.3", "one more thing"));
  await settle();
  session.complete();
  await settle();
  assert.equal(session.prompts.length, 2);
  assert.ok(session.prompts[1]!.includes("one more thing"));
  await r.close();
});

test("a connect's runtime, profile and model decide the session", async () => {
  const r = new Rig();
  const m = say("<@UGPT> refactor this");
  await r.accept(m, "gpt");
  await settle();
  assert.deepEqual([r.claude.count(), r.codex.count()], [0, 1]);
  const row = r.session(sessionKey("gpt", "C1", m.threadTs));
  assert.deepEqual([row.profile, row.model], ["cx", null]);
  const n = message();
  await r.accept(n);
  await settle();
  assert.equal(r.session(sessionKey("cl", "C1", n.threadTs)).model, "opus");
  assert.equal(r.claude.last().options.effort, "high", "the connect's effort reaches the runtime");
  // Guidance only: no identity, no name (what it is called comes with each message, per connect).
  const instructions = r.claude.last().options.instructions;
  assert.ok(!instructions.includes("You are ") && !instructions.includes("Claude bot"));
  await r.close();
});

test("two connects in one thread keep separate sessions, share its messages and reply through their own connection", async () => {
  const r = new Rig();
  const root = say("<@UBOT> <@UGPT> compare notes");
  await r.accept(root);
  await r.accept(root, "gpt");
  await settle();
  const both = reply(root, "9999.7", "both of you: go");
  await r.accept(both);
  await r.accept(both, "gpt");
  await settle();
  assert.ok(r.claude.last().steers[0]!.includes("both of you"));
  assert.ok(r.codex.last().steers[0]!.includes("both of you"));
  await r.call(sessionKey("gpt", "C1", root.threadTs), "chat_post", { to: `C1/${root.threadTs}`, text: "from gpt" });
  assert.deepEqual(r.gptChat.texts(), ["from gpt"]);
  assert.deepEqual(r.chat.texts(), []);
  const thread = r.thread("C1", root.threadTs);
  assert.deepEqual(
    r.store.threadSessions(thread.id).map((m) => [m.session, m.connect]),
    [
      [sessionKey("cl", "C1", root.threadTs), "cl"],
      [sessionKey("gpt", "C1", root.threadTs), "gpt"],
    ],
  );
  assert.deepEqual(
    r.said(thread.id).map((m) => m.authorKind),
    ["person", "person", "agent"],
    "each message once, however many connects saw it",
  );
  await r.close();
});

test("a mention of one connect does not start a session for another connect that sees the message", async () => {
  const r = new Rig();
  await r.accept(say("<@UBOT> only claude", { addressed: false }), "gpt");
  await settle();
  assert.equal(r.codex.count(), 0);
  await r.close();
});

test("after a restart, a cut-off turn is resumed", async () => {
  const first = new Rig();
  await first.accept(message());
  await settle();
  const runtimeId = first.claude.last().sessionId;
  // Same store, new hub and drivers: what a restart looks like.
  const claude = new FakeDriver("claude");
  const hub = first.newHub({ chats: (id) => (id === "cl" ? first.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  hub.recover();
  await settle();
  assert.equal(claude.last().options.resume, runtimeId);
  assert.ok(claude.last().prompts[0]!.includes("restarted while you were in the middle of a turn"));
  await hub.shutdown();
  await first.close();
});

test("handed over to the next station, a running turn goes on and what came meanwhile reaches it", async () => {
  const first = new Rig();
  const m = message();
  await first.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const old = first.claude.last();
  const handed = await first.hub.handOver();
  assert.equal(handed.sessions.length, 1);
  assert.ok(handed.sessions[0]!.turn !== null, "its turn goes along");
  assert.ok(existsSync(join(first.dir, "run", "handover.json")), "written for the next station");
  // Said while handing over: it waits, pending, and the old station does nothing more with it.
  await first.accept(reply(m, "9999.7", "one more thing"));
  await settle();
  assert.ok(old.steers.length === 0 && old.prompts.length === 1);
  // The next station: same store, new hub and drivers, what was handed over read back from its file.
  const claude = new FakeDriver("claude");
  const hub = first.newHub({ chats: (id) => (id === "cl" ? first.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await hub.takeUp();
  assert.ok(!existsSync(join(first.dir, "run", "handover.json")), "taken");
  hub.recover();
  await settle();
  const taken = claude.last();
  assert.equal(taken.sessionId, old.sessionId);
  assert.deepEqual(taken.prompts, [], "not resumed: its turn runs on");
  assert.ok(taken.steers[0]?.includes("one more thing"), JSON.stringify(taken.steers));
  assert.ok(first.store.getSession(key)!.running);
  // Its end is the next station's: it ended without a state, so it nudges.
  taken.complete();
  await settle();
  assert.equal(taken.prompts.length, 1, JSON.stringify(taken.prompts));
  assert.ok((taken.prompts as string[])[0]!.includes(NUDGE));
  await hub.shutdown();
  await first.close();
});

test("held turns start once released, with what waited meanwhile", async () => {
  const r = new Rig({ maxNudges: 0 });
  const m = message();
  await r.accept(m);
  await settle();
  const session = r.claude.last();
  session.complete();
  await settle();
  r.hub.hold("drain");
  await r.accept(reply(m, "9999.8", "next"));
  await settle();
  assert.equal(session.prompts.length, 1, "held: nothing starts");
  assert.ok(!r.hub.anyRunning());
  r.hub.release("drain");
  await settle();
  assert.equal(session.prompts.length, 2);
  assert.ok(session.prompts[1]!.includes("next"));
  await r.close();
});

test("a station in no workspace starts no turn until it joins one, whatever a drain does", async () => {
  const r = new Rig({ maxNudges: 0 });
  r.hub.hold("unbound");
  const m = message();
  await r.accept(m);
  await settle();
  assert.equal(r.claude.count(), 0, "unbound: no runtime session starts");
  const key = sessionKey("cl", m.channel, m.threadTs);
  assert.equal(r.store.pendingMessages(key).length, 1, "the message waits");
  // A drain that comes and goes meanwhile does not let it through.
  r.hub.hold("drain");
  r.hub.release("drain");
  await settle();
  assert.equal(r.claude.count(), 0);
  assert.ok(r.hub.holds("unbound"));
  r.hub.release("unbound");
  await settle();
  const session = r.claude.last();
  assert.equal(session.prompts.length, 1, "joined: what waited starts");
  assert.ok(session.prompts[0]!.includes("hello"));
  await r.close();
});

test("leaving the workspace ends the runtimes, and coming back resumes the cut-off turn with what it was given", async () => {
  const r = new Rig({ maxNudges: 0 });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  await r.accept(reply(m, "9999.5", "and the docs too"));
  await settle();
  assert.ok(session.steers[0]!.includes("and the docs too"), "given to the running turn");
  assert.deepEqual(r.store.pendingMessages(key), []);
  // An idle process of another session ends as well.
  await r.accept(say("<@UBOT> other"));
  await settle();
  const idle = r.claude.last();
  idle.complete();
  await settle();
  assert.ok(idle !== session && !idle.busyNow && !idle.disposed);

  const said = r.chat.texts().length;
  r.hub.hold("unbound");
  await r.hub.suspendAll();
  assert.ok(session.disposed && idle.disposed, "every runtime process ended");
  assert.equal(session.aborts, 0, "ended, not just interrupted");
  assert.deepEqual([r.claude.shutdowns, r.codex.shutdowns], [1, 1], "and the drivers' own");
  assert.ok(!r.hub.anyRunning());
  assert.equal(r.hub.processState(key), "cold");
  assert.ok(r.session(key).running, "kept for recover");
  assert.deepEqual(
    r.store.pendingMessages(key).map((p) => p.message.text),
    ["and the docs too"],
    "what it may not have read waits again",
  );
  // What the ended runtime still says is not taken: no nudge, no notice, nothing started.
  session.complete();
  await settle();
  assert.equal(r.claude.count(), 2, "no runtime starts while out of the workspace");
  assert.equal(r.chat.texts().length, said, "nothing said in the threads");
  assert.ok(r.session(key).running);

  // Back in the workspace: recover, then release.
  r.hub.recover();
  r.hub.release("unbound");
  await settle();
  const resumed = r.claude.last();
  assert.equal(r.claude.count(), 3, "only the cut-off turn resumes; the idle session waits for its next message");
  assert.equal(resumed.options.resume, session.sessionId, "on the same runtime session");
  assert.ok(matches(resumed.prompts[0]!, ["restarted while you were in the middle of a turn", "and the docs too"]), JSON.stringify(resumed.prompts));
  assert.deepEqual(r.store.pendingMessages(key), []);
  await r.close();
});

test("a turn that had already said final is not resumed after leaving the workspace", async () => {
  const r = new Rig({ maxNudges: 0 });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  r.hub.hold("unbound");
  await r.hub.suspendAll();
  assert.ok(r.claude.last().disposed);
  assert.ok(!r.session(key).running);
  r.hub.recover();
  r.hub.release("unbound");
  await settle();
  assert.equal(r.claude.count(), 1, "nothing to resume");
  await r.close();
});

test("when the runtime session cannot be resumed, a new one starts and is told to catch up", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const old = r.claude.last();
  old.end({ kind: "failed", reason: "exited", message: "gone" });
  old.events({ type: "closed", why: "gone" });
  await settle();
  r.claude.unresumable.add(old.sessionId);
  await r.accept(reply(m, "9999.4", "still there?"));
  await settle();
  const now = r.claude.last();
  assert.notEqual(now, old);
  assert.equal(now.options.resume, undefined);
  assert.ok(matches(now.prompts[0]!, ["could not be restored", "still there?"]));
  await r.close();
});

test("idle claude processes beyond the warm limit are evicted, oldest first, as soon as another goes idle", async () => {
  const time = testClock();
  const r = new Rig({ maxWarmClaude: 1, warmMinutes: 0, clock: time.clock });
  await r.accept(message({ ts: "1.1", threadTs: "1.1" }));
  await settle();
  r.claude.last().end({ kind: "aborted" });
  await settle();
  assert.ok(!r.claude.last().disposed, "within the limit");
  // Idle for a moment longer than the next one will be.
  await time.adjust(5);
  await r.accept(message({ ts: "2.1", threadTs: "2.1" }));
  await settle();
  r.claude.last().end({ kind: "aborted" });
  await settle();
  assert.deepEqual(
    r.claude.sessions.map((s) => s.disposed),
    [true, false],
  );
  await r.close();
});

test("an idle process beyond the limit is evicted at its own deadline", async () => {
  const time = testClock();
  const r = new Rig({ maxWarmClaude: 0, warmMinutes: 0.002, clock: time.clock }); // 120 ms
  await r.accept(message());
  await settle();
  r.claude.last().end({ kind: "aborted" });
  await settle();
  await time.adjust(119);
  await settle();
  assert.ok(!r.claude.last().disposed, "not idle long enough yet");
  await time.adjust(1);
  await settle();
  assert.ok(r.claude.last().disposed);
  await r.close();
});

test("a running turn is never evicted", async () => {
  const time = testClock();
  const r = new Rig({ maxWarmClaude: 0, warmMinutes: 0, clock: time.clock });
  await r.accept(message());
  await time.adjust(60_000);
  await settle();
  assert.ok(!r.claude.last().disposed);
  await r.close();
});

test("a single-session connect gathers every thread into one session and replies where asked", async () => {
  const r = new Rig();
  const a = say("<@UTEAM> build A");
  await r.accept(a, "team");
  await settle();
  await r.accept(say("unrelated chatter", { addressed: false, channel: "C2" }), "team");
  const b = say("<@UTEAM> build B", { channel: "C2" });
  await r.accept(b, "team");
  await settle();
  assert.equal(r.claude.count(), 1);
  assert.equal(r.store.listSessions().length, 1);
  const bound = r.store.binding("team")!;
  assert.equal(r.session(bound).scope, "all");
  const session = r.claude.last();
  assert.ok(matches(session.steers[0]!, ['thread="C2/', "build B"]));
  assert.ok(![...session.steers, ...session.prompts].join("\n").includes("unrelated chatter"));
  // A reply in a thread the session already follows needs no mention.
  await r.accept(reply(a, "9999.8", "and tests too"), "team");
  await settle();
  assert.ok(session.steers.at(-1)!.includes("and tests too"));
  await r.call(bound, "chat_post", { to: `C2/${b.threadTs}`, text: "B done" });
  assert.deepEqual(r.teamChat.posts, [[{ channel: "C2", threadTs: b.threadTs }, "B done"]]);
  await r.close();
});

test("a single-session connect without require mention hears every message", async () => {
  const r = new Rig({ teamRequireMention: false });
  await r.accept(say("anyone around?", { addressed: false }), "team");
  await settle();
  assert.equal(r.claude.count(), 1);
  assert.ok(r.claude.last().prompts[0]!.includes("anyone around?"));
  await r.close();
});

test("a single-session connect can be pointed at a new or an existing session", async () => {
  const r = new Rig();
  await r.accept(say("<@UTEAM> one"), "team");
  await settle();
  const old = r.store.binding("team")!;
  const fresh = bindSingle(r.hub, "team", null, "值班", null);
  assert.notEqual(fresh, old);
  assert.equal(r.session(fresh).title, "值班");
  await r.accept(say("<@UTEAM> two"), "team");
  await settle();
  assert.equal(r.claude.count(), 2, "the new binding got its own runtime session");
  assert.ok(r.claude.last().prompts[0]!.includes("two"));

  // Binding a session that another connect started: replies still go out where each thread came in.
  const m = say("<@UBOT> from cl");
  await r.accept(m);
  await settle();
  const clKey = sessionKey("cl", "C1", m.threadTs);
  bindSingle(r.hub, "team", clKey, null, null);
  const t = say("<@UTEAM> via team", { channel: "C7" });
  await r.accept(t, "team");
  await settle();
  assert.deepEqual(
    r.store.sessionThreads(clKey).map((x) => [x.thread.channel, x.connect]),
    [
      ["C7", "team"],
      ["C1", "cl"],
    ],
  );
  await r.call(clKey, "chat_post", { to: `C7/${t.threadTs}`, text: "to team thread" });
  await r.call(clKey, "chat_post", { to: `C1/${m.threadTs}`, text: "to cl thread" });
  assert.deepEqual(r.teamChat.texts(), ["to team thread"]);
  assert.deepEqual(r.chat.texts(), ["to cl thread"]);
  assert.throws(() => bindSingle(r.hub, "team", sessionKey("gpt", "C1", "1.1"), null, null), /unknown session/);
  assert.throws(() => bindSingle(r.hub, "cl", null, null, null), /not single-session/);
  await r.close();
});

test("a chat opened on the admin page reaches the session like Slack, and the agent answers there", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  r.claude.last().complete();
  await settle();
  r.store.setTitle(key, "排查");
  const thread = openChat(r.hub, key, "local", null);
  assert.equal(thread.title, "排查", "its own chat keeps the name the session was given");
  sayIn(r.hub, thread.id, "local", "现在进展如何？");
  await settle();
  const prompt = r.claude.last().prompts.at(-1)!;
  assert.ok(prompt.includes(`<message via="web" connect="ember" thread="EMBER/${thread.threadTs}" from="管理员 (local)"`), prompt);
  assert.ok(prompt.includes("现在进展如何"));
  const to = `EMBER/${thread.threadTs}`;
  assert.equal(await r.call(key, "chat_post", { to, text: "快好了", kind: "all_done", done: "答了进展：快好了，没有别的要做" }), `Posted to ${to}, and recorded state all_done.`);
  assert.deepEqual(
    r.said(thread.id).map((x) => [x.authorKind, x.text]),
    [
      ["person", "现在进展如何？"],
      ["agent", "快好了"],
    ],
  );
  assert.equal(r.chat.texts().length, 1, "only the Slack thread's own answer went to Slack");
  assert.ok((await r.call(key, "chat_history", { to })).includes("现在进展如何"));
  assert.throws(() => openChat(r.hub, "nope", "local", null), /unknown session/);
  await r.close();
});

test("a person's message in a chat with several agents reaches each of them once", async () => {
  const r = new Rig();
  const one = newSession(r.hub, chat("claude"));
  const two = newSession(r.hub, chat("codex"));
  addToThread(r.hub, one[1].id, two[0]);
  const quote = { author: "Claude", role: "agent", ts: "1.000001", text: "上一条", comment: "这里" };
  sayIn(r.hub, one[1].id, "a@example.com", "你们俩分一下工", [], [quote]);
  await settle();
  for (const driver of [r.claude, r.codex]) {
    assert.equal(driver.count(), 1);
    const prompt = driver.last().prompts[0]!;
    assert.ok(prompt.includes("[Quote] From your own earlier message 1.000001 in this conversation:\n> 上一条\nTheir comment on it: 这里\n\n你们俩分一下工"), prompt);
  }
  assert.equal(r.store.pendingMessages(one[0]).length + r.store.pendingMessages(two[0]).length, 0);
  const said = r.said(one[1].id);
  assert.equal(said[0]!.text, "你们俩分一下工", "the words are stored as typed; the quote is a column");
  assert.equal(said[0]!.quotes[0]!.comment, "这里");
  await r.close();
});

test("a pending message edited before delivery reaches the agent as edited", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const session = r.claude.last();
  session.unsteerable = true;
  const edited = reply(m, "9999.5", "first draft");
  await r.accept(edited);
  await settle(); // it waits: the running turn takes no steer
  await r.hub.receive("cl", { type: "changed", channel: "C1", threadTs: m.threadTs, ts: edited.ts, text: "final words" });
  session.complete();
  await settle();
  const prompt = session.prompts[1]!;
  assert.ok(prompt.includes("final words") && !prompt.includes("first draft"), prompt);
  assert.equal(r.store.pendingMessages(sessionKey("cl", "C1", m.threadTs)).length, 0);
  await r.close();
});

test("deleting a session ends its process and removes its workspace and the threads only it was in", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const row = r.session(key);
  // The runtime's transcript lives in the profile's home and stays.
  const transcript = join(r.config.profiles[0]!.home, "projects", "x", `${row.runtimeSessionId}.jsonl`);
  mkdirSync(dirname(transcript), { recursive: true });
  writeFileSync(transcript, "{}\n");
  assert.ok(existsSync(row.workspace));
  await deleteSession(r.hub, key);
  assert.ok(r.claude.last().disposed);
  assert.equal(r.store.getSession(key), null);
  assert.equal(r.store.threadAt("slack:T1", "C1", m.threadTs), null);
  assert.ok(!existsSync(row.workspace));
  assert.ok(!existsSync(dirname(row.workspace)));
  assert.ok(existsSync(transcript));
  await r.close();
});

test("archiving hands an idle session to cold storage, never on a timer for what was archived before", async () => {
  const packed: string[] = [];
  const restored: string[] = [];
  const r = new Rig({ cold: { isCold: () => false, restore: (key) => void restored.push(key), pack: (key) => void packed.push(key) } });
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_state", { kind: "final" });
  r.claude.last().complete();
  await settle();
  r.store.setArchived(key, true, MANUAL);
  autoArchive(r.hub, Date.now() + 3 * 86_400_000);
  await settle();
  assert.deepEqual(packed, [], "a timer must not pack old archives");
  archive(r.hub, key, true);
  await settle();
  assert.ok(r.claude.last().disposed, "its idle process ends");
  assert.deepEqual(packed, [key], "an explicit archive does");
  archive(r.hub, key, false);
  assert.deepEqual(restored, [key]);
  await r.close();
});

test("idle chats that are done are archived by the station; busy, blocked, unread and bound ones stay", async () => {
  const r = new Rig();
  const day = 86_400_000;
  const m = message();
  await r.accept(m);
  await settle();
  const idle = sessionKey("cl", "C1", m.threadTs);
  await r.call(idle, "chat_state", { kind: "final" });
  r.claude.last().complete();
  await settle();
  const b = say("<@UBOT> look", { channel: "C2" });
  await r.accept(b);
  await settle();
  const blocked = sessionKey("cl", "C2", b.threadTs);
  await r.call(blocked, "chat_state", { kind: "block" });
  r.claude.last().complete();
  await settle();
  const [web, thread] = newSession(r.hub, chat());
  sayIn(r.hub, thread.id, "local", "hi");
  await settle();
  // The agent's answer is unread: the chat stays.
  await r.call(web, "chat_post", { to: `EMBER/${thread.threadTs}`, text: "hello", kind: "final" });
  r.claude.last().complete();
  await settle();
  await r.accept(say("<@UBOT> hi"), "team");
  await settle();
  const bound = r.store.binding("team")!;
  await r.call(bound, "chat_state", { kind: "final" });
  r.claude.last().complete();
  await settle();

  autoArchive(r.hub, Date.now());
  assert.ok(r.store.listSessions().every((s) => s.archivedAt === null), "nothing has idled a day yet");
  const later = Date.now() + 2 * day;
  autoArchive(r.hub, later);
  assert.equal(r.session(idle).archivedBy, AUTO);
  assert.equal(r.session(blocked).archivedAt, null, "stopped at a block");
  assert.equal(r.session(web).archivedAt, null, "unread");
  assert.equal(r.session(bound).archivedAt, null, "a single-session connect's");
  r.store.setRead("local", thread.id, r.store.lastEntry(thread.id));
  // A job of its own still up (a watch above all): it stays until the job is over.
  r.store.insertJob(watchJob(web));
  autoArchive(r.hub, later);
  assert.equal(r.session(web).archivedAt, null, "its watch runs");
  r.store.jobEnded("job_w", "stopped", null);
  // Pinned by anyone, it stays in the lists.
  r.store.setPin("dev@example.com", web, true);
  autoArchive(r.hub, later);
  assert.equal(r.session(web).archivedAt, null, "pinned");
  r.store.setPin("dev@example.com", web, false);
  autoArchive(r.hub, later);
  assert.equal(r.session(web).archivedBy, AUTO);
  assert.ok(r.store.getThread(thread.id)!.hiddenAt !== null, "its own chat with it");
  // Someone writes in the Slack thread again: its session is back.
  await r.accept(reply(m, "9999.5", "<@UBOT> one more"));
  assert.equal(r.session(idle).archivedAt, null);
  // A chat opened with a session that has one is a chat of its own, archived alone.
  archive(r.hub, web, false);
  r.store.setTitle(web, "值班");
  const second = openChat(r.hub, web, "local", null);
  assert.equal(second.home, null);
  assert.equal(second.title, null, "a chat of its own does not take the session's name");
  archiveChat(r.hub, second.id, true);
  assert.equal(r.session(web).archivedAt, null);
  assert.ok(r.store.getThread(second.id)!.hiddenAt !== null);
  archiveChat(r.hub, thread.id, true);
  assert.equal(r.session(web).archivedBy, MANUAL);
  await settle();
  await r.close();
});

test("kept chats survive idle archiving but can be archived by hand", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, chat());
  r.store.keepChat("alice", thread.id);
  autoArchive(r.hub, Date.now() + 3 * 86_400_000);
  assert.equal(r.session(key).archivedAt, null);
  assert.equal(r.store.getThread(thread.id)!.hiddenAt, null);
  const second = openChat(r.hub, key, "alice", null);
  r.store.keepChat("alice", second.id);
  autoArchive(r.hub, Date.now() + 3 * 86_400_000);
  assert.equal(r.store.getThread(second.id)!.hiddenAt, null);
  archiveChat(r.hub, second.id, true);
  assert.ok(r.store.getThread(second.id)!.hiddenAt !== null);
  archiveChat(r.hub, thread.id, true);
  assert.ok(r.session(key).archivedAt !== null);
  await settle();
  await r.close();
});

const withProfile = (id: string, name: string, models: string[]) => (raw: any) => raw.profiles.push({ ...raw.profiles[0], id, name, models });

test("a session changes profile, model and effort by hand, and is taken on by another profile when its own cannot run", async () => {
  const r = new Rig();
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const refused = async (p: Promise<unknown>) => {
    try {
      await p;
    } catch (error) {
      return (error as Error).message;
    }
    throw new Error("not refused");
  };
  r.edit(withProfile("cc2", "another", ["opus"]));
  assert.ok((await refused(configure(r.hub, key, { profile: "cc2" }))).includes("正在跑"), "not while a turn runs");
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  r.claude.last().complete();
  await settle();
  await configure(r.hub, key, { profile: "cc2" });
  assert.equal(r.session(key).profile, "cc2");
  assert.ok((await refused(configure(r.hub, key, { profile: "cx" }))).includes("不能跑 Claude Code"));
  r.edit(withProfile("cc3", "third", []));
  assert.ok((await refused(configure(r.hub, key, { profile: "cc3" }))).includes("「third」没有启用 opus"), "only one with its model enabled");
  // Its model and effort change too, to what a profile of its runtime runs.
  assert.ok((await refused(configure(r.hub, key, { model: "gpt-5" }))).includes("没有能跑 gpt-5 的 Claude Code Profile"));
  assert.ok((await refused(configure(r.hub, key, { effort: "ultra" }))).includes("思考深度只有"));
  r.edit((raw) => raw.profiles.filter((p: any) => p.id === "cc" || p.id === "cc2").forEach((p: any) => (p.models = [...(p.models ?? []), "sonnet"])));
  await configure(r.hub, key, { profile: "cc2", model: "sonnet", effort: "low" });
  let row = r.session(key);
  assert.deepEqual([row.model, row.effort], ["sonnet", "low"]);
  assert.ok(row.profilePinned, "kept to it by hand");
  // Another model alone: what went with the old one starts over, the effort default and the profile the station's pick
  // among those with it enabled.
  r.edit((raw) => raw.profiles.filter((p: any) => p.id === "cc3").forEach((p: any) => (p.models = [...p.models, "haiku"])));
  await configure(r.hub, key, { model: "haiku" });
  row = r.session(key);
  assert.deepEqual([row.model, row.effort, row.profile, row.profilePinned], ["haiku", null, "cc3", false]);
  await configure(r.hub, key, { profile: "cc2", model: "sonnet", effort: "low" });
  // Given back to the station, and its own used up: the next start runs on the other one, which takes it on.
  await configure(r.hub, key, { profile: null });
  assert.ok(!r.session(key).profilePinned);
  await r.hub.evict(key);
  r.hub.accounts.setHealth((id) => (id === "cc2" ? { quota: { state: "ok", windows: [{ label: "每周", usedPercent: 100, resetsAt: null }], detail: null, checkedAt: 0 } } : {}));
  await r.accept({ ...say("<@UBOT> and the tests"), threadTs: m.threadTs });
  await settle();
  assert.equal(r.session(key).profile, "cc");
  await r.close();
});

test("a connect or a new chat can keep its sessions to one profile; otherwise the pool picks", async () => {
  const r = new Rig();
  r.edit((raw) => {
    raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "second", models: ["opus"] });
    raw.connects.find((c: any) => c.id === "cl").bind.profile = "cc2";
  });
  const m = say("<@UBOT> hi");
  await r.accept(m);
  await settle();
  const row = r.session(sessionKey("cl", "C1", m.threadTs));
  assert.deepEqual([row.profile, row.profilePinned], ["cc2", true]);
  // A new chat given a profile keeps to it; one that has not the model on is refused.
  const pinned = (model: string) => ({ ...chat(), model, profile: "cc2" });
  const [key] = newSession(r.hub, pinned("opus"));
  assert.deepEqual([r.session(key).profile, r.session(key).profilePinned], ["cc2", true]);
  assert.throws(() => newSession(r.hub, pinned("sonnet")), /没有启用 sonnet/);
  const [auto] = newSession(r.hub, chat());
  assert.ok(!r.session(auto).profilePinned);
  await r.close();
});

test("the Slack thread a turn works for says what the agent is doing until the turn ends", async () => {
  const r = new Rig();
  const m = say("<@UBOT> fix the build");
  await r.accept(m);
  await settle();
  const session = r.claude.last();
  session.events({ type: "live", event: { kind: "start", id: "t1", step: "tool", tool: "Bash" } });
  session.events({ type: "live", event: { kind: "end", id: "t1" } });
  session.complete();
  await settle();
  assert.deepEqual(
    r.chat.statuses.map((s) => s[2]),
    ["正在思考…", "正在运行命令…", "正在思考…", ""],
  );
  assert.equal(r.chat.statuses[0]![0], `C1/${m.threadTs}`);
  assert.equal(r.chat.statuses[0]![1], m.ts, "the message that started it, for the fallback reaction");
  await r.close();
});

test("agents in one thread hear each other: a post reaches the thread's other sessions, marked a bot, and not its author", async () => {
  const r = new Rig();
  const root = say("<@UBOT> <@UGPT> work this out together");
  await r.accept(root);
  await r.accept(root, "gpt");
  await settle();
  const [cl, gpt] = [sessionKey("cl", "C1", root.threadTs), sessionKey("gpt", "C1", root.threadTs)];
  await r.call(cl, "chat_state", { kind: "final" });
  await r.call(gpt, "chat_state", { kind: "final" });
  r.claude.last().complete();
  r.codex.last().complete();
  await settle();
  const before = r.claude.last().prompts.length;
  await r.call(gpt, "chat_post", { to: `C1/${root.threadTs}`, text: "I'll take the tests; can you do the build?" });
  await settle();
  const prompts = r.claude.last().prompts;
  assert.equal(prompts.length, before + 1);
  assert.ok(matches(prompts.at(-1)!, ['from="ember (<@UGPT>)" bot ts="', "\">\nI'll take the tests; can you do the build?"]), prompts.at(-1));
  assert.ok(!r.codex.last().prompts.some((p) => p.includes("I'll take the tests")), "not back to its author");
  // Slack's copy of that post, seen through the other connect, is not a message of its own.
  await r.accept(reply(root, "9999.9", "I'll take the tests; can you do the build?", { user: "UGPT" }));
  await settle();
  assert.equal(r.claude.last().prompts.length, before + 1);
  await r.close();
});

test("in a chat on the station's page with several agents, what one posts reaches the others", async () => {
  const r = new Rig();
  const one = newSession(r.hub, chat("claude"));
  const two = newSession(r.hub, chat("codex"));
  addToThread(r.hub, one[1].id, two[0]);
  sayIn(r.hub, one[1].id, "local", "分一下工");
  await settle();
  await r.call(one[0], "chat_state", { kind: "final" });
  await r.call(two[0], "chat_state", { kind: "final" });
  r.claude.last().complete();
  r.codex.last().complete();
  await settle();
  await r.call(one[0], "chat_post", { to: `EMBER/${one[1].threadTs}`, text: "我来写接口" });
  await settle();
  const heard = r.codex.last().prompts.at(-1)!;
  assert.ok(matches(heard, ['from="Claude Code" bot ts="', '">\n我来写接口']), heard);
  await r.close();
});

test("a mention Slack sends twice at once makes one session without an error", async () => {
  const r = new Rig();
  for (let i = 0; i < 20; i++) {
    const m = say("<@UBOT> fix the build", { ts: `${100 + i}.000001`, threadTs: `${100 + i}.000001` });
    // app_mention and message for the same post, handled side by side as the Slack socket does.
    await Promise.all([r.accept(m), r.accept(m)]);
  }
  await settle();
  assert.ok(!r.chat.texts().some((t) => t.includes("无法创建会话")), JSON.stringify(r.chat.texts()));
  assert.equal(r.hub.gates.size, 0);
  assert.equal(r.store.listSessions().length, 20);
  await r.close();
});

test("a turn that runs out of allowance goes on on another account, or once the session is changed", async () => {
  const r = new Rig();
  r.edit((raw) => {
    raw.profiles[0].models = ["opus"];
    raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "second" });
  });
  const spent = (text: string) => ({ kind: "failed" as const, reason: classifyResult(text), message: text });
  const m = message();
  await r.accept(m);
  await settle();
  const first = r.claude.last();
  const key = first.options.route;
  const on = r.session(key).profile;
  // Left to the station: another account takes it on, in a process of its own, and goes on.
  first.end(spent("You've hit your session limit · resets 3:40am (Asia/Tokyo)"));
  await settle();
  assert.ok(first.disposed, "its process ran on the account left");
  const second = r.claude.last();
  assert.equal(r.claude.count(), 2);
  assert.notEqual(second.options.profile.id, on);
  assert.equal(r.session(key).profile, second.options.profile.id);
  assert.ok(!r.session(key).profilePinned);
  assert.ok(r.chat.texts().every((t) => !t.includes("额度")), "it just goes on, saying nothing");
  // In a new runtime session of its own (sessions/afresh.ts).
  assert.equal(second.options.resume, undefined);
  assert.equal(second.prompts.length, 1);
  assert.ok(matches(second.prompts[0]!, ["This is a new conversation", GO_ON_AFTER_SPENT]), second.prompts[0]);
  // That one runs out too: none left, so it says so and waits.
  second.end(spent("usage limit reached"));
  await settle();
  assert.equal(r.claude.count(), 2, "no account left to go on with");
  assert.ok(matches(r.chat.lastText(), ["触发额度或限流", "usage limit reached"]));
  // Changed by hand (here: kept to the first again): it goes on by itself.
  await configure(r.hub, key, { profile: on });
  await settle();
  const third = r.claude.last();
  assert.equal(r.claude.count(), 3);
  assert.equal(third.options.profile.id, on);
  assert.equal(third.prompts.length, 1);
  assert.ok(matches(third.prompts[0]!, ["This is a new conversation", GO_ON_AFTER_SPENT]), third.prompts[0]);
  // A change after a turn that ended well starts nothing.
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  third.complete();
  await settle();
  await configure(r.hub, key, { profile: null });
  await settle();
  assert.equal(r.claude.count(), 3);
  await r.close();
});

test("on another account a conversation goes on in a new runtime session, its history read on; on its own it is taken up", async () => {
  const r = new Rig();
  r.edit((raw) => {
    raw.profiles[0].models = ["opus"];
    raw.profiles.push({ ...raw.profiles[0], id: "cc2", name: "second" });
  });
  const spent = { kind: "failed" as const, reason: classifyResult("usage limit reached"), message: "usage limit reached" };
  // The profiles share a home here, so their transcripts.
  const transcript = (id: string, said: string, context: number) => {
    const path = join(r.config.profiles[0]!.home, "projects", "-w", `${id}.jsonl`);
    mkdirSync(dirname(path), { recursive: true });
    const usage = { input_tokens: 3, cache_read_input_tokens: context - 1003, cache_creation_input_tokens: 1000 };
    writeFileSync(path, [{ type: "user", message: { role: "user", content: said } }, { type: "assistant", message: { id: `m-${id}`, role: "assistant", content: [{ type: "text", text: "ok" }], usage } }].map((l) => JSON.stringify(l)).join("\n") + "\n");
  };
  const m = message();
  await r.accept(m);
  await settle();
  const first = r.claude.last();
  const key = first.options.route;
  const on = r.session(key).profile;
  transcript(first.id(), "first", 200_000);
  first.end(spent);
  await settle();
  // Moved to the other account: not taken up there, but started afresh, told where its past is.
  const second = r.claude.last();
  assert.notEqual(second.options.profile.id, on);
  assert.equal(second.options.resume, undefined);
  assert.notEqual(second.id(), first.id());
  assert.equal(second.prompts.length, 1);
  assert.ok(matches(second.prompts[0]!, ["This is a new conversation", `session_history with chat ${key}`, `C1/${m.threadTs}`, GO_ON_AFTER_SPENT]), second.prompts[0]);
  assert.deepEqual(r.store.runtimeSessions(key).map((ran) => ran.id), [first.id(), second.id()]);
  assert.equal(r.store.ranOn(key, second.id()), second.options.profile.id);
  // Its history goes on from the first's.
  transcript(second.id(), "second", 1_000);
  assert.deepEqual(r.hub.live.before(key, 100, 100)![1].filter((e) => e.kind === "user").map((e) => e.text), ["first", "second"]);
  // Its process gone, on the same account: taken up as before.
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  second.complete();
  await settle();
  await r.hub.evict(key);
  await r.accept({ ...message(), threadTs: m.threadTs });
  await settle();
  const third = r.claude.last();
  assert.equal(third.options.resume, second.id());
  assert.ok(!third.prompts[0]!.includes("This is a new conversation"));
  // Back on the first account, however short the conversation: afresh again.
  third.end(spent);
  await settle();
  await configure(r.hub, key, { profile: on });
  await settle();
  const fourth = r.claude.last();
  assert.equal(fourth.options.resume, undefined);
  assert.ok(matches(fourth.prompts[0]!, ["This is a new conversation", GO_ON_AFTER_SPENT]), fourth.prompts[0]);
  assert.deepEqual(r.store.runtimeSessions(key).map((ran) => ran.id), [first.id(), second.id(), fourth.id()]);
  await r.close();
});

test("moved to another runtime, a conversation goes on afresh there, its history read on from what both wrote", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const first = r.claude.last();
  const key = first.options.route;
  const claudeTranscript = join(r.config.profiles[0]!.home, "projects", "-w", `${first.id()}.jsonl`);
  mkdirSync(dirname(claudeTranscript), { recursive: true });
  writeFileSync(claudeTranscript, JSON.stringify({ type: "user", message: { role: "user", content: "first" } }) + "\n");
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  first.complete();
  await settle();
  // Another runtime: not while a turn runs; the old model is the old runtime's, so the new one's default.
  await configure(r.hub, key, { runtime: "codex" });
  const moved = r.session(key);
  assert.deepEqual([moved.runtime, moved.profile, moved.model, moved.effort], ["codex", "cx", null, null]);
  await r.accept({ ...message(), threadTs: m.threadTs });
  await settle();
  assert.equal(r.claude.count(), 1);
  const second = r.codex.last();
  assert.equal(second.options.resume, undefined);
  assert.ok(matches(second.prompts[0]!, ["This is a new conversation", `session_history with chat ${key}`, `C1/${m.threadTs}`]), second.prompts[0]);
  assert.deepEqual(r.store.runtimeSessions(key), [
    { id: first.id(), runtime: "claude" },
    { id: second.id(), runtime: "codex" },
  ]);
  const rollouts = join(r.config.profiles[1]!.home, "sessions", "2026", "09", "02");
  mkdirSync(rollouts, { recursive: true });
  writeFileSync(
    join(rollouts, `rollout-2026-09-02T00-00-00-${second.id()}.jsonl`),
    [
      { type: "session_meta", payload: { id: second.id(), cwd: moved.workspace } },
      { type: "response_item", timestamp: "2026-09-02T00:00:01.000Z", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "second" }] } },
    ].map((l) => JSON.stringify(l)).join("\n") + "\n",
  );
  assert.deepEqual(r.hub.live.before(key, 100, 100)![1].filter((e) => e.kind === "user").map((e) => e.text), ["first", "second"]);
  // Back, it is not taken up where it left Claude Code either: afresh again.
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  second.complete();
  await settle();
  await configure(r.hub, key, { runtime: "claude" });
  await r.accept({ ...message(), threadTs: m.threadTs });
  await settle();
  const third = r.claude.last();
  assert.equal(r.claude.count(), 2);
  assert.equal(third.options.resume, undefined);
  assert.ok(third.prompts[0]!.includes("This is a new conversation"), third.prompts[0]);
  assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["claude", "cc"]);
  // What it cannot run is refused, and nothing changes.
  await assert.rejects(configure(r.hub, key, { runtime: "gemini" }), /unknown runtime/);
  assert.equal(r.session(key).runtime, "claude");
  await r.close();
});

test("codex model efforts validate new chats, changes and pinned accounts", async () => {
  const r = new Rig();
  r.edit((raw) => {
    const p = raw.profiles.find((p: any) => p.id === "cx");
    p.models = ["gpt-6-astra"];
    raw.profiles.push({ ...p, id: "limited" });
  });
  r.hub.accounts.setHealth((id) => ({
    check: {
      state: "ok", detail: "", models: ["gpt-6-astra"], checkedAt: 0,
      modelEfforts: { codex: { "gpt-6-astra": id === "limited" ? ["low", "medium", "high", "xhigh", "max"] : ["low", "medium", "high", "xhigh", "max", "ultra"] } },
    },
  }));
  const fresh = (profile: string | null, effort: string) => ({ runtime: "codex" as const, profile, model: "openai/gpt-6-astra", effort, createdBy: "local" });
  const [key] = newSession(r.hub, fresh(null, "max"));
  assert.equal(r.session(key).effort, "max");
  assert.throws(() => newSession(r.hub, fresh(null, "minimal")));
  assert.throws(() => newSession(r.hub, fresh(null, "ultra")));
  const [pinned] = newSession(r.hub, fresh("cx", "ultra"));
  assert.equal(r.session(pinned).effort, "ultra");
  // A profile change must not carry an unsupported depth to the destination.
  await assert.rejects(configure(r.hub, pinned, { profile: "limited" }));
  await assert.rejects(configure(r.hub, pinned, { profile: null }));
  await configure(r.hub, key, { profile: "cx", effort: "ultra" });
  assert.equal(r.session(key).effort, "ultra");
  await configure(r.hub, key, { profile: null, effort: null });
  assert.equal(r.session(key).effort, null);
  await r.close();
});

test("a session from before a change is told it once, and a new one never", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  assert.ok(!r.claude.last().prompts[0]!.includes("still.fail changed how you work"), "a new session has today's instructions");
  await r.call(key, "chat_state", { kind: "all_done", done: "答完了它问的事" });
  r.claude.last().complete();
  await settle();
  // As a session from before the notes: told them with its next turn, once.
  r.store.setToldNotes(key, 0);
  await r.accept(reply(m, "9999.1", "还有一件"));
  await settle();
  const prompts = r.claude.last().prompts;
  assert.ok(prompts.at(-1)!.startsWith("[still.fail changed how you work"), prompts.at(-1));
  const full = join(r.session(key).workspace, ".stillfail-instructions.md");
  assert.ok(prompts.at(-1)!.includes(full), "it says where today's instructions are");
  assert.equal(readFileSync(full, "utf8"), r.claude.last().options.instructions, "the file contains the full current instructions");
  assert.equal(r.store.toldNotes(key), latest());
  await r.call(key, "chat_state", { kind: "all_done", done: "答完了它问的事" });
  r.claude.last().complete();
  await settle();
  await r.accept(reply(m, "9999.2", "再一件"));
  await settle();
  assert.ok(!r.claude.last().prompts.at(-1)!.includes("still.fail changed how you work"));
  await r.close();
});

test("fast is per session, and null restores the subscription default", async () => {
  const r = new Rig();
  const [a] = newSession(r.hub, { ...chat("codex"), fast: true });
  const [b] = newSession(r.hub, chat("codex"));
  assert.equal(r.session(a).fast, true);
  assert.equal(r.session(b).fast, null);
  r.store.setRuntimeSessionId(a, "thread-a");
  r.store.setRuntimeSessionId(b, "thread-b");
  await configure(r.hub, a, { fast: false });
  assert.equal(r.store.codexSessionFast("thread-a"), false);
  assert.equal(r.store.codexSessionFast("thread-b"), null);
  await configure(r.hub, a, {});
  assert.equal(r.session(a).fast, false, "unrelated changes preserve an explicit standard speed");
  await configure(r.hub, a, { fast: null });
  assert.equal(r.session(a).fast, null);
  const [claude] = newSession(r.hub, chat("claude"));
  await assert.rejects(configure(r.hub, claude, { fast: true }));
  await r.close();
});

/// A machine with one Claude Code session and one Codex session (machine_sessions/tests.rs `machine`).
function machine(root: string, project: string) {
  const roots = { claude: join(root, ".claude/projects"), codex: join(root, ".codex/sessions") };
  const lines = (records: unknown[]) => records.map((r) => `${JSON.stringify(r)}\n`).join("");
  const cwd = project;
  // As Claude Code names a project's directory: every character but a letter or a digit as `-` (C:\a\b is C--a-b).
  const claudeDir = join(roots.claude, cwd.replace(/[^A-Za-z0-9]/g, "-"));
  mkdirSync(claudeDir, { recursive: true });
  writeFileSync(
    join(claudeDir, "11111111-aaaa-bbbb-cccc-000000000001.jsonl"),
    lines([
      { type: "ai-title", aiTitle: "Old name" },
      { type: "user", cwd, isMeta: true, timestamp: "2026-09-01T00:00:00.000Z", message: { content: "meta" } },
      { type: "user", cwd, timestamp: "2026-09-01T00:00:01.000Z", message: { content: "<command-name>/model</command-name>" } },
      { type: "user", cwd, timestamp: "2026-09-01T00:00:02.000Z", message: { content: "fix   the\nbuild" } },
      { type: "assistant", cwd, timestamp: "2026-09-01T00:00:03.000Z", message: { content: [{ type: "thinking", thinking: "hm" }, { type: "text", text: "Looking." }] } },
      { type: "assistant", cwd, timestamp: "2026-09-01T00:00:04.000Z", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: {} }] } },
      { type: "user", cwd, timestamp: "2026-09-01T00:00:05.000Z", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } },
      { type: "assistant", cwd, isSidechain: true, timestamp: "2026-09-01T00:00:05.500Z", message: { content: [{ type: "text", text: "a subagent" }] } },
      { type: "assistant", cwd, timestamp: "2026-09-01T00:00:06.000Z", message: { model: "claude-opus-5-5", content: [{ type: "text", text: "Fixed." }] } },
      { type: "assistant", cwd, isApiErrorMessage: true, timestamp: "2026-09-01T00:00:06.500Z", message: { content: [{ type: "text", text: "Not logged in · Please run /login" }] } },
      { type: "user", cwd, isCompactSummary: true, timestamp: "2026-09-01T00:00:07.000Z", message: { content: "This session is being continued…" } },
      { type: "user", cwd, timestamp: "2026-09-01T00:00:08.000Z", message: { content: [{ type: "text", text: "thanks" }] } },
      { type: "ai-title", aiTitle: "Fix the build" },
    ]),
  );
  const codexDir = join(roots.codex, "2026/09/02");
  mkdirSync(codexDir, { recursive: true });
  writeFileSync(
    join(codexDir, "rollout-2026-09-02T00-00-00-22222222-aaaa-bbbb-cccc-000000000001.jsonl"),
    lines([
      { type: "session_meta", payload: { id: "22222222-aaaa-bbbb-cccc-000000000001", cwd } },
      { type: "response_item", timestamp: "2026-09-02T00:00:01.000Z", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "add a test" }] } },
      { type: "turn_context", payload: { model: "gpt-5.5" } },
      { type: "response_item", timestamp: "2026-09-02T00:00:03.000Z", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Added." }] } },
    ]),
  );
  return roots;
}

test("a session the machine kept goes on in a chat, run in its own directory, with what was said in it", async () => {
  const { find } = await import("../src/read/machine.ts");
  const { continueMachineSession } = await import("../src/sessions/lifecycle.ts");
  const { readTimeline } = await import("../src/read/transcript.ts");
  const r = new Rig();
  const root = join(r.dir, "machine");
  const project = join(root, "app");
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "main.rs"), "fn main() {}");
  const roots = machine(root, project);
  const found = find(roots, "claude", "11111111-aaaa-bbbb-cccc-000000000001")!;
  const [key, thread] = continueMachineSession(r.hub, roots, found, "local");
  const row = r.session(key);
  assert.equal(row.cwd, project);
  assert.equal(row.runtimeSessionId, found.id);
  assert.ok(row.workspace.endsWith("workspace") && !row.workspace.startsWith(project));
  assert.equal(r.store.getThread(thread.id)!.title, "Fix the build");
  const copy = join(r.dir, "transcripts/claude", found.path.slice(roots.claude.length + 1));
  assert.deepEqual(readFileSync(copy), readFileSync(found.path));
  const said = r.said(thread.id);
  // Only a note of where it came from, linking to what was said before: nothing of it is copied into the chat.
  assert.equal(said.length, 1);
  assert.equal(said[0]!.authorKind, "ember");
  assert.ok(said[0]!.text.startsWith("接着本机 Claude Code 在"), said[0]!.text);
  const last = readTimeline("claude", found.path).length - 1;
  assert.ok(said[0]!.text.endsWith(`[查看之前的对话](?history=${key}&entry=${last})`), said[0]!.text);
  await settle();
  assert.equal(r.claude.count(), 0, "what was said before is not handed to the agent again");

  sayIn(r.hub, thread.id, "local", "and the tests");
  await settle();
  const opened = r.claude.last();
  assert.equal(opened.options.resume, found.id);
  assert.equal(opened.options.cwd, project);
  assert.equal(opened.options.instructions, "", "its system prompt is left as it began");
  assert.equal(opened.prompts.length, 1);
  const first = opened.prompts[0]!;
  assert.ok(first.startsWith("This session began in a terminal and now goes on in still.fail"), first);
  assert.ok(first.includes("<stillfail-instructions>") && first.includes("and the tests"));
  assert.ok(first.includes(`- Project directory: ${project}.`));
  opened.complete();
  await settle();
  sayIn(r.hub, thread.id, "local", "one more");
  await settle();
  assert.ok(!r.claude.last().prompts.at(-1)!.includes("<stillfail-instructions>"), "said once");

  // Going on with it again is the same chat.
  const again = find(roots, "claude", found.id)!;
  assert.equal(continueMachineSession(r.hub, roots, again, "local")[0], key);

  // Deleting the chat leaves the project and the machine's transcript alone.
  r.claude.last().complete();
  await settle();
  await deleteSession(r.hub, key);
  assert.ok(existsSync(join(project, "main.rs")));
  assert.ok(existsSync(found.path));
  await r.close();
});

// root reads a directory whatever its mode says.
// Windows has no chmod that keeps the owner out.
test("a directory the station may not read is told as that, not left to the agent to fail in", { skip: process.getuid?.() === 0 || process.platform === "win32" }, async () => {
  const { find } = await import("../src/read/machine.ts");
  const { continueMachineSession } = await import("../src/sessions/lifecycle.ts");
  const r = new Rig();
  const root = join(r.dir, "machine");
  const project = join(root, "Documents/proj");
  mkdirSync(project, { recursive: true });
  const roots = machine(root, project);
  const found = find(roots, "claude", "11111111-aaaa-bbbb-cccc-000000000001")!;
  // As macOS privacy protection answers a station nobody gave access to: it may stat the directory, not list it.
  chmodSync(project, 0o000);
  try {
    assert.throws(() => continueMachineSession(r.hub, roots, found, "local"), /没有权限读取目录/);
    assert.equal(r.store.listSessions().length, 0);
    // One continued while it could be read, and read no more later: its turn says why, and no agent is started.
    chmodSync(project, 0o755);
    const [, thread] = continueMachineSession(r.hub, roots, found, "local");
    chmodSync(project, 0o000);
    sayIn(r.hub, thread.id, "local", "go on");
    await settle();
    assert.equal(r.claude.count(), 0);
    const notice = r.said(thread.id).at(-1)!;
    assert.equal(notice.authorKind, "ember");
    assert.ok(notice.text.includes("没有权限读取目录") && notice.text.includes(project), notice.text);
  } finally {
    chmodSync(project, 0o755);
  }
  await r.close();
});

test("a session whose directory is gone is not continued", async () => {
  const { find } = await import("../src/read/machine.ts");
  const { continueMachineSession } = await import("../src/sessions/lifecycle.ts");
  const r = new Rig();
  const root = join(r.dir, "machine");
  const roots = machine(root, join(root, "gone"));
  const found = find(roots, "codex", "22222222-aaaa-bbbb-cccc-000000000001")!;
  assert.throws(() => continueMachineSession(r.hub, roots, found, "local"), /已经不在了/);
  assert.equal(r.store.listSessions().length, 0);
  await r.close();
});


test("removing an account blocks later turns in its warm session and keeps pending input", async () => {
  const r = new Rig({ maxNudges: 0, warmMinutes: 0 });
  const m = message();
  await r.accept(m);
  await settle();
  const running = r.claude.last();
  r.config.profiles = r.config.profiles.filter((p) => p.id !== "cc");
  // The accepted turn can finish. The next message must not use the cached runtime.
  running.end({ kind: "aborted" });
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.accept(reply(m, "9999.8", "work after disabling"));
  await settle();
  assert.equal(running.prompts.length, 1);
  assert.equal(r.claude.count(), 1);
  assert.equal(r.store.pendingMessages(key).length, 1);
  assert.ok(r.store.getSession(key));
  await r.close();
});
