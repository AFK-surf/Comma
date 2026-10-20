// The agents' tools (src/tools/chat.ts, slack.ts, stations.ts, adb.ts, feedback.ts) on the hub: their definitions, and
// what they do (ported from the Rust station's hub tests): posts, cards, states and what they are about, history, other
// chats, session_send, slack_api, files, titles, the archive suggestion after all_done.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { cardArg, optionsArg } from "../src/sessions/args.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { fromPeer } from "../src/sessions/messages.ts";
import { forPeer } from "../src/sessions/others.ts";
import { Refused } from "../src/sessions/neighbours.ts";
import { newSession, say as sayIn } from "../src/sessions/lifecycle.ts";
import { review, reviewUndecided } from "../src/sessions/review.ts";
import { cleanTitle } from "../src/sessions/titles.ts";
import { adbTools } from "../src/tools/adb.ts";
import { archiveTools } from "../src/tools/archive.ts";
import { chatTools } from "../src/tools/chat.ts";
import { feedbackTools } from "../src/tools/feedback.ts";
import { stationTools } from "../src/tools/stations.ts";
import { DEFAULT_POLICY } from "../src/sessions/archive-policy.ts";
import { Rig, matches, message, reply, say, settle } from "./hub-fakes.ts";

type Json = any;

// ── the definitions ──

test("every tool has a name, a description and an object's input schema; the chat tools in their order", () => {
  const r = new Rig();
  const ours = [...chatTools(r.hub), ...archiveTools(r.hub), ...stationTools(() => null), ...adbTools(() => [], () => null), ...feedbackTools(r.store, () => null, () => null)];
  assert.deepEqual(
    chatTools(r.hub).map((t) => t.name),
    ["chat_post", "slack_api", "chat_state", "chat_history", "chat_list", "chat_read", "session_send", "session_history"],
  );
  assert.equal(new Set(ours.map((t) => t.name)).size, ours.length, "no name twice");
  for (const tool of ours) {
    assert.match(tool.name, /^[a-z_]+$/);
    assert.ok(tool.description.length > 0, tool.name);
    assert.equal((tool.inputSchema as Json).type, "object", tool.name);
    for (const required of (tool.inputSchema as Json).required ?? []) assert.ok(required in (tool.inputSchema as Json).properties, `${tool.name}: ${required}`);
  }
  void r.close();
});

// ── posts ──

test("chat_post with kind final posts and settles the turn without a nudge", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const to = `C1/${m.threadTs}`;
  // "final", from a session whose instructions are from before all_done, is all_done.
  assert.equal(await r.call(key, "chat_post", { to, text: "**done**", kind: "final" }), `Posted to ${to}, and recorded state all_done.`);
  r.claude.last().complete();
  await settle();
  assert.equal(r.claude.last().prompts.length, 1);
  assert.deepEqual(r.chat.posts, [[{ channel: "C1", threadTs: m.threadTs }, "**done**"]]);
  await r.close();
});

test("the agent's posts are recorded in the thread, and chat_history shows them as its own", async () => {
  const r = new Rig();
  const m = say("<@UBOT> look");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const to = `C1/${m.threadTs}`;
  await r.call(key, "chat_post", { to, text: "looking", kind: "block" });
  const said = r.said(r.thread("C1", m.threadTs).id);
  assert.deepEqual([said[0]!.authorKind, said[1]!.authorKind, said[1]!.author, said[1]!.declared], ["person", "agent", key, "need_help"]);
  assert.equal(r.store.pendingMessages(key).length, 0, "an agent's own post is not delivered back to it");
  const history = await r.call(key, "chat_history", { to });
  assert.ok(matches(history, ['from="U1" ts="', '">\n<@UBOT> look', 'from="you" ts="', '">\nlooking']), history);
  await r.close();
});

test("an agent reads another session's chat by its link or address, and finds it in the list", async () => {
  const r = new Rig();
  const [a, b] = [say("<@UBOT> look at the build"), say("<@UBOT> what did the other chat find?")];
  await r.accept(a);
  await r.accept(b);
  await settle();
  const [keyA, keyB] = [sessionKey("cl", "C1", a.threadTs), sessionKey("cl", "C1", b.threadTs)];
  const toA = `C1/${a.threadTs}`;
  await r.call(keyA, "chat_post", { to: toA, text: "the build is green" });
  // Not one of B's conversations, yet B reads it: by its address, by its chat's link, by its session key.
  const link = `https://ember.test/w/ws/s/st/chats/${keyA.replaceAll(":", "%3A")}`;
  for (const chat of [toA, link, keyA]) {
    const read = await r.call(keyB, "chat_read", { chat });
    assert.ok(matches(read, [`Conversation ${toA}; its agents: ${keyA}.`, 'from="U1"', "look at the build", `from="${keyA}" bot`, "the build is green"]), read);
  }
  const listed = await r.call(keyB, "chat_list", { query: "BUILD" });
  assert.ok(matches(listed, [`- ${toA} (Slack thread)`, `agents: ${keyA};`, "the build is green"]), listed);
  assert.ok(!listed.includes(b.threadTs), listed);
  const mine = await r.call(keyB, "chat_list", {});
  assert.ok(mine.includes(`${keyB} (you)`), mine);
  assert.equal(await r.call(keyB, "session_history", { chat: toA }), `Session ${keyA} has no execution history yet.`);
  assert.ok((await r.refused(keyB, "chat_read", { chat: "https://ember.test/o/ws/st/nope" })).includes("not on this station"));
  assert.ok((await r.refused(keyB, "chat_read", { chat: "C9/1.000001" })).includes("no conversation C9/1.000001"));
  await r.close();
});

test("session_history reads a session's transcript, numbered as the pages number it", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const row = r.session(key);
  const dir = join(r.config.profiles[0]!.home, "projects", "x");
  const { mkdirSync } = await import("node:fs");
  mkdirSync(dir, { recursive: true });
  const line = (text: string, id: string) => JSON.stringify({ type: "assistant", timestamp: "2026-09-26T00:00:00Z", message: { id, content: [{ type: "text", text }] } });
  writeFileSync(join(dir, `${row.runtimeSessionId}.jsonl`), `${line("one", "m1")}\n${line("two", "m2")}\n`);
  const history = await r.call(key, "session_history", { chat: key, max_chars: 100 });
  assert.ok(matches(history, [`Session ${key} (claude, opus): entries #0–#1 of 2.`, "#0 ", "one", "#1 ", "two"]), history);
  await r.close();
});

test("chat_state refuses kinds it does not know", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  assert.ok((await r.refused(sessionKey("cl", "C1", m.threadTs), "chat_state", { kind: "wait" })).includes('"all_done" or "need_human" (or "waiting"'));
  await settle();
  await r.close();
});

test("chat_post and chat_history need an explicit thread of this session", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  assert.ok(matches(await r.refused(key, "chat_post", { text: "hi" }), ["to is required", "C1/"]));
  assert.ok((await r.refused(key, "chat_post", { to: "C1", text: "hi" })).includes("CHANNEL/THREAD_TS"));
  assert.ok((await r.refused(key, "chat_post", { to: "C9/1.1", text: "hi" })).includes("not a conversation of this session"));
  assert.ok((await r.refused(key, "chat_history", {})).includes("to is required"));
  assert.deepEqual(r.chat.texts(), []);
  await r.close();
});

const web = (createdBy = "ada@x.com") => ({ runtime: "claude" as const, createdBy });

test("a post carries a card, kept with it and checked", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web());
  sayIn(r.hub, thread.id, "ada@x.com", "fix the spacing");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  const kept = () => {
    const n = r.said(thread.id).at(-1)!.n;
    return r.store.entriesBetween(thread.id, n, n)[0]!;
  };
  const options = [
    { label: " 按今天累计 ", detail: "重连不清零，零点归零", recommended: true },
    { label: "先不改", detail: "", recommended: false },
  ];
  const shown = [{ label: "按今天累计", detail: "重连不清零，零点归零", recommended: true }, { label: "先不改" }];
  // An options card, with the turn ending need_help: the card is the message's, the state the turn's.
  let said = await r.call(key, "chat_post", { to, text: "「共」改成按今天累计吗？", kind: "need_help", need: "选统计口径", card: { type: "options", options } });
  assert.ok(said.startsWith(`Posted to ${to}, and recorded state need_human. People can pick: 按今天累计 (recommended); 先不改;`), said);
  let entry = kept();
  assert.deepEqual(entry.card, { type: "options", options: shown });
  assert.deepEqual(entry.options, shown, "kept as options too: what stations and clients from before cards read");
  assert.equal(entry.declared, "need_help");
  // A text card, on a progress post (no kind): any post may carry one.
  said = await r.call(key, "chat_post", { to, text: "测试 key 是多少？", card: { type: "text", placeholder: " sk_test_… " } });
  assert.ok(said.startsWith(`Posted to ${to}. People can write their answer`), said);
  entry = kept();
  assert.deepEqual([entry.card, entry.options, entry.declared], [{ type: "text", placeholder: "sk_test_…" }, undefined, null]);
  await r.call(key, "chat_post", { to, text: "名字？", card: '{"type": "text"}' });
  assert.deepEqual(kept().card, { type: "text" }, "as JSON text, from a runtime whose tool list is from before cards");
  // need_decision, from before cards: an options card, the turn need_help needing what it asks.
  said = await r.call(key, "chat_post", { to, text: "**「共」改成按今天累计吗？**\n细节", kind: "need_decision", options });
  assert.ok(said.includes("recorded state need_human. People can pick"), said);
  assert.deepEqual([kept().card, kept().declared], [{ type: "options", options: shown }, "need_help"]);
  r.claude.last().complete();
  await settle();
  assert.equal(r.store.lastTurn(key)!.need, "「共」改成按今天累计吗？", "it needs what the post asks");
  // Options as JSON text, asking with block; a bare phrase is a label.
  said = await r.call(key, "chat_post", { to, text: "选哪个？", kind: "block", options: '["A", {"label": "B"}]' });
  assert.ok(said.includes("recorded state need_human."), said);
  assert.deepEqual(kept().options, [{ label: "A" }, { label: "B" }]);
  // Options without a kind: an options card all the same.
  await r.call(key, "chat_post", { to, text: "顺便：哪个？", options: [{ label: "A" }] });
  assert.deepEqual(kept().card, { type: "options", options: [{ label: "A" }] });
  // A post without a card keeps none.
  await r.call(key, "chat_post", { to, text: "进度" });
  assert.deepEqual([kept().card, kept().options], [undefined, undefined]);
  const refused = (args: Json) => r.refused(key, "chat_post", args);
  const one = [{ label: "A" }];
  assert.ok((await refused({ to, text: "x", card: { type: "poll" } })).includes('unknown card type "poll": the types known are options, text'));
  assert.ok((await refused({ to, text: "x", card: {} })).includes("one of options, text"));
  assert.ok((await refused({ to, text: "x", card: ["A"] })).includes("card must be an object"));
  assert.ok((await refused({ to, text: "x", card: { type: "options" } })).includes("an options card has options"));
  assert.ok((await refused({ to, text: "x", card: { type: "options", options: one }, options: one })).includes("not also as options"));
  assert.ok((await refused({ to, text: "x", card: { type: "text", placeholder: "字".repeat(81) } })).includes("at most 80"));
  assert.ok((await refused({ to, text: "x", kind: "need_help", card: { type: "text" } })).includes("need is required"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision" })).includes("carries options"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: [] })).includes("1 to 6"));
  const seven = Array.from({ length: 7 }, (_, i) => ({ label: `选项${i}` }));
  assert.ok((await refused({ to, text: "x", card: { type: "options", options: seven } })).includes("1 to 6"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: [{ label: " " }] })).includes("label is empty"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: [{ label: "A" }, { label: "A" }] })).includes("repeats"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: [{ label: "A", recommended: true }, { label: "B", recommended: true }] })).includes("only one"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: { label: "A" } })).includes("must be an array"));
  assert.ok((await refused({ to, text: "x", kind: "need_decision", options: "not json" })).includes("must be an array"));
  assert.ok((await refused({ to, files: [], card: { type: "text" } })).includes("text is empty"));
  await r.close();
});

test("answering a clarification cannot silently restore need_human", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web());
  sayIn(r.hub, thread.id, "ada@x.com", "改一下");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  await r.call(key, "chat_post", { to, text: "可以合并吗？", card: { type: "options", options: [{ label: "合并" }] } });
  assert.equal(await r.call(key, "chat_state", { kind: "need_human", need: "确认合并" }), "Recorded state need_human.");
  r.claude.last().complete();
  await settle();
  sayIn(r.hub, thread.id, "ada@x.com", "跟随订阅就是标准吧");
  await settle();
  const person = r.said(thread.id).at(-1)!.ts;
  await r.call(key, "chat_post", { to, text: "默认情况下是标准。" });
  assert.ok((await r.refused(key, "chat_state", { kind: "need_human", need: "等待确认是否合并" })).includes("requires a visible question"));
  assert.ok((await r.refused(key, "chat_state", { kind: "need_human", need: "确认合并", about: person })).includes("your visible question"));
  // A visible plain-text request works without forcing a new card.
  await r.call(key, "chat_post", { to, text: "还需要你确认：这版可以合并吗？", kind: "need_human", need: "确认合并" });
  await r.close();
});

test("a state says which message it is about, the pending card by default", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web());
  sayIn(r.hub, thread.id, "ada@x.com", "上线吧");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  const about = () => r.store.lastTurn(key)!.about;
  // need_help after a card: about the card, by default.
  await r.call(key, "chat_post", { to, text: "合吗？", card: { type: "options", options: [{ label: "合" }] } });
  const card = r.said(thread.id).at(-1)!;
  await r.call(key, "chat_post", { to, text: "等你看一下", kind: "need_help", need: "决定合不合" });
  r.claude.last().complete();
  await settle();
  assert.deepEqual(about(), { thread: thread.id, seq: card.n, ts: card.ts });
  // all_done about the message with the result, given by its ts; with chat_state too.
  sayIn(r.hub, thread.id, "ada@x.com", "合");
  await settle();
  await r.call(key, "chat_post", { to, text: "已合进 main" });
  const result = r.said(thread.id).at(-1)!;
  assert.equal(await r.call(key, "chat_state", { kind: "all_done", done: "已合进 main 82f108a5", about: result.ts }), "Recorded state all_done.");
  r.claude.last().complete();
  await settle();
  assert.deepEqual(about(), { thread: thread.id, seq: result.n, ts: result.ts });
  // waiting about the message saying what was started; need_help with no card waiting is about nothing.
  sayIn(r.hub, thread.id, "ada@x.com", "再跑一遍测试");
  await settle();
  await r.call(key, "chat_post", { to, text: "测试开始跑了" });
  const started = r.said(thread.id).at(-1)!;
  await r.call(key, "chat_state", { kind: "waiting", seconds: 60, for: "测试跑完", about: started.ts });
  r.claude.last().complete();
  await settle();
  assert.equal(about()?.seq, started.n);
  sayIn(r.hub, thread.id, "ada@x.com", "怎样了");
  await settle();
  await r.call(key, "chat_post", { to, text: "卡住了", kind: "need_help", need: "要 key" });
  r.claude.last().complete();
  await settle();
  assert.equal(about(), null, "no card waiting, none given");
  // A ts not in the chat, or about with no kind: refused.
  sayIn(r.hub, thread.id, "ada@x.com", "给你");
  await settle();
  assert.ok((await r.refused(key, "chat_post", { to, text: "x", kind: "all_done", done: "已合进 main 82f108a5", about: "1.000001" })).includes("about must be the ts of a message"));
  assert.ok((await r.refused(key, "chat_state", { kind: "all_done", done: "已合进 main 82f108a5", about: "1.000001" })).includes("about must be the ts of a message"));
  assert.ok((await r.refused(key, "chat_post", { to, text: "x", about: started.ts })).includes("about goes with kind"));
  await r.close();
});

test("options are refused in a Slack thread", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  assert.ok((await r.refused(key, "chat_post", { to: `C1/${m.threadTs}`, text: "选哪个？", kind: "need_decision", options: [{ label: "A" }] })).includes("only in still.fail chats"));
  assert.ok((await r.refused(key, "chat_post", { to: `C1/${m.threadTs}`, text: "key？", card: { type: "text" } })).includes("only in still.fail chats"));
  await r.close();
});

test("a card is pending until a person writes, and a newer one replaces it", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web());
  sayIn(r.hub, thread.id, "ada@x.com", "fix the spacing");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  const pending = () => {
    const p = r.store.pendingCard(thread.id);
    return p ? [p[0].n, p[1]] : null;
  };
  assert.equal(pending(), null);
  // Help asked for asks nothing to pick.
  await r.call(key, "chat_post", { to, text: "要 key", kind: "need_help", need: "要 Stripe 的测试 key" });
  assert.equal(pending(), null);
  await r.call(key, "chat_post", { to, text: "合吗？", kind: "need_decision", options: [{ label: "合" }] });
  const first = r.said(thread.id).at(-1)!.n;
  assert.deepEqual(pending(), [first, { type: "options", options: [{ label: "合" }] }]);
  // The agent saying more without options leaves it pending; only people answer it.
  await r.call(key, "chat_post", { to, text: "顺便说一下进度" });
  assert.equal(pending()?.[0], first);
  // A newer one replaces it.
  await r.call(key, "chat_post", { to, text: "还是先问这个：留哪个？", kind: "need_decision", options: [{ label: "留旧的" }, { label: "留新的" }] });
  const second = r.said(thread.id).at(-1)!.n;
  assert.equal(pending()?.[0], second);
  // Any person's message after it answers it, quoting it or not.
  sayIn(r.hub, thread.id, "bob@x.com", "都不要，换个思路");
  assert.equal(pending(), null);
  await r.call(key, "chat_post", { to, text: "那这样？", kind: "need_decision", options: [{ label: "好" }] });
  assert.ok(pending() !== null);
  // A text card replaces it as well, on a post with no kind.
  await r.call(key, "chat_post", { to, text: "域名填哪个？", card: { type: "text", placeholder: "example.com" } });
  const text = r.said(thread.id).at(-1)!.n;
  assert.deepEqual(pending(), [text, { type: "text", placeholder: "example.com" }]);
  sayIn(r.hub, thread.id, "ada@x.com", "still.fail");
  assert.equal(pending(), null);
  await settle();
  await r.close();
});

test("a turn ends all_done, needing a decision or help, or waiting, and the words from before still count", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const to = `C1/${m.threadTs}`;
  const last = () => r.store.lastTurn(key)!;
  // need_help says what is needed: kept with the turn; refused without it.
  assert.ok((await r.refused(key, "chat_post", { to, text: "卡住了", kind: "need_help" })).includes("need is required"));
  assert.equal(await r.call(key, "chat_post", { to, text: "卡住了", kind: "need_human", need: " 要 Stripe 的测试 key " }), `Posted to ${to}, and recorded state need_human.`);
  r.claude.last().complete();
  await settle();
  assert.deepEqual([last().declared, last().ending, last().need], ["block", "need_help", "要 Stripe 的测试 key"], "clients from before read block");
  assert.equal(r.claude.last().prompts.length, 1, "a state: not nudged");
  // need goes only with need_help; need_decision only posted, with options.
  await r.accept(reply(m, "9999.1", "给你 key"));
  await settle();
  assert.ok((await r.refused(key, "chat_state", { kind: "all_done", need: "x", done: "y" })).includes('only with kind "need_human"'));
  assert.ok((await r.refused(key, "chat_state", { kind: "all_done" })).includes("done is required"));
  // done is a reason people can trust, not the word done.
  for (const empty of ["做完了", " 完成。", "已完成", "Done!", "ok", "好了", "全部搞定"]) {
    assert.ok((await r.refused(key, "chat_state", { kind: "all_done", done: empty })).includes("done must say why nothing in the chat is left"), empty);
  }
  assert.ok((await r.refused(key, "chat_state", { kind: "need_help", need: "x", done: "y" })).includes('only with kind "all_done"'));
  assert.ok((await r.refused(key, "chat_state", { kind: "need_decision" })).includes("posted with chat_post"));
  assert.ok((await r.refused(key, "chat_state", { kind: "need_help" })).includes("need is required"));
  assert.ok((await r.refused(key, "chat_state", { kind: "done" })).includes("all_done"));
  assert.ok((await r.refused(key, "chat_state", { kind: "need_help", need: "确认一下要不要上线" })).includes("requires a visible question"));
  await r.call(key, "chat_post", { to, text: "确认一下要不要上线？" });
  const question = r.said(r.store.sessionThreads(key)[0]!.thread.id).at(-1)!.ts;
  assert.equal(await r.call(key, "chat_state", { kind: "need_help", need: "确认一下要不要上线", about: question }), "Recorded state need_human.");
  r.claude.last().complete();
  await settle();
  assert.deepEqual([last().ending, last().need], ["need_help", "确认一下要不要上线"]);
  // all_done says what the chat ends with, kept as need is.
  await r.accept(reply(m, "9999.2", "上了"));
  await settle();
  assert.equal(await r.call(key, "chat_state", { kind: "all_done", done: "已合并所有代码" }), "Recorded state all_done.");
  r.claude.last().complete();
  await settle();
  assert.deepEqual([last().ending, last().need], ["all_done", "已合并所有代码"]);
  // The words from before: block needs no need; final is all_done.
  await r.accept(reply(m, "9999.25", "上吧"));
  await settle();
  assert.equal(await r.call(key, "chat_state", { kind: "block" }), "Recorded state need_human.");
  r.claude.last().complete();
  await settle();
  assert.deepEqual([last().declared, last().ending, last().need], ["block", "need_help", null]);
  await r.accept(reply(m, "9999.3", "好了吗"));
  await settle();
  assert.equal(await r.call(key, "chat_state", { kind: "final" }), "Recorded state all_done.");
  r.claude.last().complete();
  await settle();
  assert.deepEqual([last().declared, last().ending], ["final", "all_done"]);
  assert.deepEqual(
    r.said(r.thread("C1", m.threadTs).id).flatMap((x) => x.declared ?? []),
    ["need_help"],
    "posts keep today's words",
  );
  await r.close();
});

test("an agent can withdraw its own card without posting or finishing work", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web("local"));
  const to = `EMBER/${thread.threadTs}`;
  await r.call(key, "chat_post", { to, text: "保留吗？", card: { type: "text" } });
  const first = r.said(thread.id).at(-1)!;
  assert.ok(!r.store.withdrawCard("someone-else", thread.id, first.ts));
  await assert.rejects(r.call(key, "chat_post", { to, withdraw: first.ts, text: "混在一起" }));
  assert.ok(r.store.pendingCard(thread.id) !== null);
  for (let i = 0; i < 2; i++) await r.call(key, "chat_post", { to, withdraw: first.ts });
  assert.equal(r.store.pendingCard(thread.id), null);
  assert.equal(r.said(thread.id).length, 1, "no new message or deleted question");
  await r.call(key, "chat_post", { to, text: "另一个问题？", card: { type: "options", options: [{ label: "好" }] } });
  await r.call(key, "chat_post", { to, withdraw: first.ts });
  assert.ok(r.store.pendingCard(thread.id) !== null, "retry cannot withdraw the newer card");
  await r.close();
});

test("only explicit, valid option actions close silently; cards keep explicit assignees", () => {
  const parsed = optionsArg([{ label: "不需要部署", action: "close" }, { label: "不需要处理" }, { label: "部署", action: "reply" }])!;
  assert.equal(parsed[0].action, "close");
  assert.equal(parsed[1].action, undefined, "labels never imply silent closure");
  assert.equal(parsed[2].action, "reply");
  assert.throws(() => optionsArg([{ label: "不需要", action: "typo" }]));
  for (const base of [{ type: "text" }, { type: "options", options: [{ label: "好" }] }]) {
    assert.equal(cardArg(base, undefined).assignee, undefined);
    const card: Json = { ...base, assignee: " Owner@Example.com " };
    assert.equal(cardArg(card, undefined).assignee, "owner@example.com");
    for (const bad of ["小王", "", ["owner@example.com"], "a@b@c"]) {
      card.assignee = bad;
      assert.throws(() => cardArg(card, undefined));
    }
  }
});

// ── files ──

test("web posts deliver local file links, and refuse missing files before posting", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web("local"));
  const workspace = r.session(key).workspace;
  const source = join(workspace, "report.txt");
  writeFileSync(source, "original report");
  const to = `EMBER/${thread.threadTs}`;
  await r.call(key, "chat_post", { to, text: `Read [report](${source})` });
  const posted = r.said(thread.id).at(-1)!;
  assert.equal(posted.text, "Read [report](report%2Etxt)");
  assert.equal(posted.attachments.length, 1);
  assert.equal(posted.attachments[0]!.name, "report.txt");
  writeFileSync(source, "changed report");
  assert.equal(readFileSync(posted.attachments[0]!.path, "utf8"), "original report");
  const count = r.said(thread.id).length;
  assert.ok((await r.refused(key, "chat_post", { to, text: "[report](/tmp/stillfail-missing-file.txt)" })).includes("correct the path"));
  assert.equal(r.said(thread.id).length, count);
  await r.close();
});

test("files posted to Slack go into the thread; apps without files:write link to still.fail", async () => {
  const r = new Rig({ link: true });
  const m = say("<@UBOT> chart it");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const to = `C1/${m.threadTs}`;
  const workspace = r.session(key).workspace;
  for (const name of ["shot.png", "weather.html"]) writeFileSync(join(workspace, name), "x");
  const link = `https://ember.test/o/ws/st/cl%3AC1%3A${m.threadTs}`;
  await r.call(key, "chat_post", { to, text: "图在这", files: ["shot.png"] });
  assert.deepEqual([r.chat.lastText(), r.chat.files.at(-1)], ["图在这", ["shot.png"]]);
  await r.call(key, "chat_post", { to, text: "图表", files: ["shot.png", "weather.html"] });
  assert.equal(r.chat.lastText(), "图表");
  assert.deepEqual(r.chat.files.at(-1), ["shot.png", "weather.html"]);
  const last = r.said(r.thread("C1", m.threadTs).id).at(-1)!;
  assert.deepEqual([last.text, last.attachments.length], ["图表\n\n[weather.html](weather.html)", 2], "still.fail keeps both, the figure placed");
  r.chat.noFiles = true;
  await r.call(key, "chat_post", { to, text: "再看", files: ["shot.png"] });
  assert.equal(r.chat.lastText(), `再看\n\n<${link}?file=shot.png|在 still.fail 里查看附件>`, "no files:write: linked as before");
  assert.deepEqual(r.chat.files.at(-1), []);
  await r.close();
});

// ── titles ──

test("an agent names its chat once, and again only after people said enough; never over people's name nor while it is open", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web("local"));
  sayIn(r.hub, thread.id, "local", "帮我看下这个");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  const post = (title: string) => r.call(key, "chat_post", { to, text: "ok", title });
  const named = () => r.store.getThread(thread.id)!.autoTitle;
  assert.equal(await post("  登录\n排查。 "), `Posted to ${to}. Titled the chat "登录 排查".`);
  assert.equal(named(), "登录 排查");
  assert.equal(await post("登录 排查"), `Posted to ${to}.`, "the same name: nothing to say");
  assert.ok((await post("登录问题排查")).includes("Title not changed: people have said too little"));
  for (let n = 0; n < 5; n++) sayIn(r.hub, thread.id, "local", `再看 ${n}`);
  await settle();
  assert.ok((await post("部署失败")).endsWith('Titled the chat "部署失败".'));
  assert.equal(r.store.autoTitle(thread.id).changes, 1);
  // Someone has it open: the new name waits for them to leave.
  for (let n = 0; n < 5; n++) sayIn(r.hub, thread.id, "local", `又一件 ${n}`);
  r.store.setRead("local", thread.id, r.store.lastEntry(thread.id));
  await settle();
  assert.ok((await post("证书过期")).endsWith('The chat will be titled "证书过期" once nobody has it open.'));
  assert.equal(named(), "部署失败");
  // A name people gave stays.
  r.store.setThreadTitle(thread.id, "值班");
  assert.ok((await post("别的")).includes("Title not changed: people named this chat"));
  // No title given: the post as before.
  assert.equal(await r.call(key, "chat_post", { to, text: "ok" }), `Posted to ${to}.`);
  await r.close();
});

test("a title that waits is given once nobody has the chat open", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web("local"));
  sayIn(r.hub, thread.id, "local", "帮我看下这个");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  await r.call(key, "chat_post", { to, text: "ok", title: "登录" });
  for (let n = 0; n < 5; n++) sayIn(r.hub, thread.id, "local", `再看 ${n}`);
  r.store.setRead("local", thread.id, r.store.lastEntry(thread.id));
  await settle();
  assert.ok((await r.call(key, "chat_post", { to, text: "ok", title: "部署" })).includes("once nobody has it open"));
  t.mock.timers.tick(60_000);
  await settle();
  assert.equal(r.store.getThread(thread.id)!.autoTitle, "登录", "still open");
  t.mock.timers.tick(3 * 60_000);
  await settle();
  assert.equal(r.store.getThread(thread.id)!.autoTitle, "部署");
  await r.close();
});

test("a Slack agent names its list entry, with the same rename limits and a manual title kept", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const to = `C1/${m.threadTs}`;
  const post = (title: string) => r.call(key, "chat_post", { to, text: "ok", title });
  const thread = r.thread("C1", m.threadTs);
  assert.ok((await post("登录排查")).endsWith('Titled the chat "登录排查".'));
  assert.equal(r.thread("C1", m.threadTs).autoTitle, "登录排查");
  assert.equal(await post("登录排查"), `Posted to ${to}.`);
  assert.ok((await post("部署失败")).includes("people have said too little"));
  for (let change = 0; change < 3; change++) {
    for (let n = 0; n < 5; n++) await r.accept(reply(m, `${20000 + change * 5 + n}.000100`, "继续排查"));
    await settle();
    const said = await post(`新话题 ${change}`);
    assert.ok(said.includes(change < 2 ? "Titled the chat" : "changed as often as it may be"), said);
  }
  r.store.setThreadTitle(thread.id, "手动标题");
  assert.ok((await post("自动标题")).includes("people named this chat"));
  assert.equal(r.thread("C1", m.threadTs).title, "手动标题");
  await r.close();
});

test("a chat that starts a watch may be renamed for it at once", async () => {
  const r = new Rig();
  const [key, thread] = newSession(r.hub, web("local"));
  sayIn(r.hub, thread.id, "local", "帮我盯着 CI");
  await settle();
  const to = `EMBER/${thread.threadTs}`;
  const post = (title: string) => r.call(key, "chat_post", { to, text: "ok", title });
  assert.ok((await post("CI")).endsWith('Titled the chat "CI".'));
  assert.ok((await post("监控 · CI")).includes("Title not changed: people have said too little"));
  r.store.insertJob({ id: "job_w", sessionKey: key, name: "盯 CI", command: "sleep 600", cwd: "/", port: null, token: "tw", state: "running", pgid: null, exitCode: null, startedAt: Date.now(), endedAt: null, restarts: 0, log: "/dev/null", watch: true });
  assert.ok((await post("监控 · CI")).endsWith('Titled the chat "监控 · CI".'), "a watch runs: at once");
  await r.close();
});

test("titles are one short line", () => {
  assert.equal(cleanTitle("  修一下\n登录。"), "修一下 登录");
  assert.equal(Array.from(cleanTitle("长".repeat(40))).length, 30);
  assert.equal(cleanTitle(" 。 "), "");
});

// ── slack_api ──

test("slack_api calls Slack as the session's bot; a thread it writes in becomes its own; one another session has is refused", async () => {
  const r = new Rig();
  const [mine, theirs] = [say("<@UBOT> look around"), say("<@UBOT> something else")];
  await r.accept(mine);
  await r.accept(theirs);
  await settle();
  const key = sessionKey("cl", "C1", mine.threadTs);
  const history = { ok: true, messages: [{ ts: "1.1", text: "hello" }] };
  r.chat.answers.set("conversations.history", history);
  assert.equal(await r.call(key, "slack_api", { method: "conversations.history", params: { channel: "C1", limit: 1 } }), JSON.stringify(history));
  assert.deepEqual(r.chat.calls.at(-1), ["conversations.history", { channel: "C1", limit: 1 }]);
  // Not the app itself, and not another session's thread.
  assert.ok((await r.refused(key, "slack_api", { method: "apps.manifest.update", params: {} })).includes("not for agents"));
  assert.ok((await r.refused(key, "slack_api", { method: "chat.postMessage", params: { channel: "C1", thread_ts: theirs.threadTs, text: "hi" } })).includes("another session's"));
  // A new message: its thread is this session's now, and a reply there comes to it.
  r.chat.answers.set("chat.postMessage", { ok: true, ts: "7777.1" });
  await r.call(key, "slack_api", { method: "chat.postMessage", params: { channel: "C2", text: "a new topic" } });
  const started = r.thread("C2", "7777.1");
  assert.deepEqual(
    r.store.threadSessions(started.id).map((m) => m.session),
    [key],
  );
  assert.deepEqual(
    r.said(started.id).map((m) => [m.authorKind, m.text]),
    [["agent", "a new topic"]],
  );
  const agent = r.claude.sessions.find((s) => s.options.route === key)!;
  await r.call(key, "chat_state", { kind: "final" });
  agent.complete();
  await settle();
  await r.accept(say("a reply to it", { channel: "C2", threadTs: "7777.1", ts: "7777.2", addressed: false }));
  await settle();
  assert.ok(agent.prompts.at(-1)!.includes("a reply to it"));
  await r.close();
});

// ── session_send ──

test("an agent writes to another session's chat, which sees whom it is from", async () => {
  const r = new Rig({ link: true });
  const [a, b] = [say("<@UBOT> build it"), say("<@UBOT> test it")];
  await r.accept(a);
  await r.accept(b);
  await settle();
  const [keyA, keyB] = [sessionKey("cl", "C1", a.threadTs), sessionKey("cl", "C1", b.threadTs)];
  const linkB = `https://ember.test/o/ws/st/${keyB.replaceAll(":", "%3A")}`;
  const sent = await r.call(keyA, "session_send", { to: linkB, text: "the build is at /tmp/out" });
  assert.ok(sent.includes(`C1/${b.threadTs}`) && sent.includes(keyB), sent);
  // Posted in B's thread for people to see, headed with A's chat, and handed to B.
  const [place, said] = r.chat.posts.at(-1)!;
  assert.deepEqual(place, { channel: "C1", threadTs: b.threadTs });
  const linkA = `https://ember.test/o/ws/st/${keyA.replaceAll(":", "%3A")}`;
  assert.ok(matches(said, [`<${linkA}|`, ">", "\n\nthe build is at /tmp/out"]), said);
  const last = r.said(r.thread("C1", b.threadTs).id).at(-1)!;
  assert.deepEqual([last.authorKind, last.author, last.text], ["agent", keyA, said]);
  assert.deepEqual(
    r.store.pendingMessages(keyB).map((p) => p.message.text),
    [said],
  );
  assert.deepEqual(r.store.pendingMessages(keyA), [], "not handed back to its sender");
  // By session key too; not to itself, nor into a conversation it is in.
  await r.call(keyB, "session_send", { to: keyA, text: "tests pass" });
  assert.ok((await r.refused(keyA, "session_send", { to: keyA, text: "hi" })).includes("chat_post"));
  assert.ok((await r.refused(keyA, "session_send", { to: `C1/${a.threadTs}`, text: "hi" })).includes("chat_post"));
  await r.close();
});

test("a message to another station's session goes through the station transport, and arrives there", async () => {
  const r = new Rig({ link: true });
  const [a, b] = [say("<@UBOT> build it"), say("<@UBOT> test it")];
  await r.accept(a);
  await r.accept(b);
  await settle();
  const [keyA, keyB] = [sessionKey("cl", "C1", a.threadTs), sessionKey("cl", "C1", b.threadTs)];
  const asked: [string, Json][] = [];
  r.hub.onPeer(async (station, request) => {
    asked.push([station, request]);
    return { thread: "EMBER/2.000001" };
  });
  const sent = await r.call(keyA, "session_send", { to: "https://ember.test/o/ws/far/s%3A1", text: "ready?" });
  assert.ok(sent.includes("station far") && sent.includes("EMBER/2.000001"), sent);
  const [station, request] = asked.pop()!;
  assert.equal(station, "far");
  assert.deepEqual([request.method, request.to, request.session, request.text], ["session.message", "s:1", keyA, "ready?"]);
  assert.equal(request.from.link, `https://ember.test/o/ws/st/${keyA.replaceAll(":", "%3A")}`);
  // The other way: what a session there sent arrives in B's chat, from that station's session.
  const from = { title: "部署", link: "https://ember.test/o/ws/far/s%3A1" };
  const got = await fromPeer(r.hub, "far", { method: "session.message", session: "s:1", to: keyB, text: "yes", from });
  assert.equal(got.thread, `C1/${b.threadTs}`);
  const last = r.said(r.thread("C1", b.threadTs).id).at(-1)!;
  assert.deepEqual([last.authorKind, last.author], ["agent", "far/s:1"]);
  assert.ok(matches(last.text, ["<https://ember.test/o/ws/far/s%3A1|部署>", "\n\nyes"]), last.text);
  assert.equal(r.store.pendingMessages(keyB).length, 1);
  await assert.rejects(fromPeer(r.hub, "far", { session: "s:1", to: "nobody", text: "yes" }));
  await r.close();
});

test("a chat on another station of the workspace is read there, by its link", async () => {
  const r = new Rig({ link: true });
  const [a, b] = [say("<@UBOT> build it"), say("<@UBOT> what did it find?")];
  await r.accept(a);
  await r.accept(b);
  await settle();
  const [keyA, keyB] = [sessionKey("cl", "C1", a.threadTs), sessionKey("cl", "C1", b.threadTs)];
  await r.call(keyA, "chat_post", { to: `C1/${a.threadTs}`, text: "the build is green" });
  const asked: [string, Json][] = [];
  r.hub.onPeer(async (station, request) => {
    asked.push([station, request]);
    return { text: "Conversation EMBER/2.000001; its agents: s:1.\nit works" };
  });
  // A still.fail link and a chat's page (as a reference is written) both name the station.
  for (const chat of ["https://ember.test/o/ws/far/s%3A1", "/w/ws/s/far/chats/s%3A1?history=s%3A1&entry=3"]) {
    const read = await r.call(keyB, "chat_read", { chat, limit: 5 });
    assert.ok(matches(read, ["station far", "it works"]), read);
    const [station, request] = asked.pop()!;
    assert.equal(station, "far");
    assert.deepEqual([request.method, request.tool, request.session, request.args], ["session.read", "chat_read", keyB, { chat, limit: 5 }]);
  }
  await r.call(keyB, "session_history", { chat: "https://ember.test/o/ws/far/s%3A1" });
  assert.equal(asked.pop()![1].tool, "session_history");
  // This station's own link is read here.
  const here = await r.call(keyB, "chat_read", { chat: `https://ember.test/o/ws/st/${keyA.replaceAll(":", "%3A")}` });
  assert.ok(here.includes("the build is green") && !here.includes("station far"), here);
  assert.equal(asked.length, 0);
  // A station from before reads: it says so.
  r.hub.onPeer(async () => {
    throw new Refused("remote tasks are not enabled for this source station");
  });
  assert.ok((await r.refused(keyB, "chat_read", { chat: "https://ember.test/o/ws/far/s%3A1" })).includes("not updated yet"));
  // The other way: what a session there reads here.
  const got = await forPeer(r.hub, "far", { method: "session.read", session: "s:1", tool: "chat_read", args: { chat: keyA } });
  assert.ok(matches(got.text, [`Conversation C1/${a.threadTs}`, "the build is green"]), got.text);
  const steps = await forPeer(r.hub, "far", { method: "session.read", session: "s:1", tool: "session_history", args: { chat: keyA } });
  assert.equal(steps.text, `Session ${keyA} has no execution history yet.`);
  await assert.rejects(forPeer(r.hub, "far", { method: "session.read", session: "s:1", tool: "chat_post", args: { chat: keyA } }));
  await assert.rejects(forPeer(r.hub, "far", { method: "session.read", session: "s:1", tool: "chat_read", args: {} }));
  await r.close();
});

// ── the archive suggestion after all_done ──

/// A local decision provider (Jev's shape): tests routing and what is recorded, not a model's judgement.
async function provider(complete: boolean) {
  const server = createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      // The default policy's options: answered (archive) or awaiting_review (not), the rest hardly.
      const [done, human] = complete ? [0.96, 0.01] : [0.01, 0.96];
      const probabilities = { ...Object.fromEntries(DEFAULT_POLICY.options.map((o) => [o.id, 0.005])), answered: done, awaiting_review: human };
      const body = JSON.stringify({ model: "test-jev", answers: { decision: { type: "choice", probabilities } } });
      res.writeHead(200, { "content-type": "application/json" }).end(body);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/systemone`, server };
}

function installDecisionProfile(r: Rig, endpoint: string) {
  r.edit((raw) => {
    raw.automaticDecisions = { completion: { enabled: true, model: "test-jev" } };
    raw.profiles[0].env = { TYPESAFE_API_KEY: "profile-test-key", TYPESAFE_BASE_URL: endpoint.replace(/\/systemone$/, "") };
  });
  const profile = r.config.profiles[0]!;
  const capability = { state: "ready", detail: "test", model: "test-jev", provider: "jev", fingerprint: fingerprint(profile), models: ["test-jev"] };
  r.hub.accounts.setHealth((id) => (id === profile.id ? { check: { decision: capability, state: "ok", detail: "", models: null, checkedAt: 0 } } : {}));
}

test("a chat the decision finds finished is recommended for the archive, until anyone speaks", async () => {
  const r = new Rig();
  const m = say("<@UBOT> what does this setting do?");
  await r.accept(m);
  await settle();
  const key = `cl:C1:${m.threadTs}`;
  const { url, server } = await provider(true);
  installDecisionProfile(r, url);
  const before = r.chat.texts().length;
  // The agent's word is taken at once: it posts, its turn ends all_done, and nothing waited for the model.
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "It controls retention.", kind: "all_done", done: "Explained the setting and its effect" });
  assert.equal(r.chat.texts().length, before + 1);
  await review(r.hub, key);
  assert.ok(r.store.archiveSuggested(r.thread("C1", m.threadTs).id), "the decision found nothing left to do");
  // Anyone saying anything since makes the recommendation stale: it goes by itself.
  await r.accept(reply(m, "9999.0001", "and the default?"));
  await settle();
  assert.ok(!r.store.archiveSuggested(r.thread("C1", m.threadTs).id));
  server.close();
  await r.close();
});

test("an all_done is never held back, and a chat with something left is not recommended", async () => {
  const r = new Rig();
  const m = say("<@UBOT> ship the requested fix");
  await r.accept(m);
  await settle();
  const key = `cl:C1:${m.threadTs}`;
  const to = `C1/${m.threadTs}`;
  // The model says a person is needed: all_done and final both post and record all the same.
  const { url, server } = await provider(false);
  installDecisionProfile(r, url);
  for (const [tool, kind] of [["chat_post", "all_done"], ["chat_post", "final"], ["chat_state", "all_done"]] as const) {
    const before = r.chat.texts().length;
    await r.call(key, tool, { to, text: "Ready, approve merging?", kind, done: "Branch is ready and tests passed" });
    assert.equal(r.chat.texts().length, before + (tool === "chat_post" ? 1 : 0));
  }
  await review(r.hub, key);
  assert.ok(!r.store.archiveSuggested(r.thread("C1", m.threadTs).id));
  server.close();
  // An outage of the model does not stop an agent either, and recommends nothing.
  installDecisionProfile(r, "http://127.0.0.1:1/systemone");
  await r.call(key, "chat_post", { to, text: "done", kind: "all_done", done: "The release has been confirmed" });
  await review(r.hub, key);
  assert.ok(!r.store.archiveSuggested(r.thread("C1", m.threadTs).id));
  await r.close();
});

test("nothing is recommended while the rule is off or its model is not verified", async () => {
  const r = new Rig();
  const m = say("<@UBOT> explain retention");
  await r.accept(m);
  await settle();
  const key = `cl:C1:${m.threadTs}`;
  const { url, server } = await provider(true);
  installDecisionProfile(r, url);
  const args = { to: `C1/${m.threadTs}`, text: "Here is the answer", kind: "all_done", done: "The factual question was answered" };
  r.edit((raw) => (raw.automaticDecisions.completion.model = "not-the-verified-model"));
  await r.call(key, "chat_post", args);
  await review(r.hub, key);
  assert.ok(!r.store.archiveSuggested(r.thread("C1", m.threadTs).id));
  r.edit((raw) => (raw.automaticDecisions.completion = { model: "test-jev", enabled: false }));
  await r.call(key, "chat_post", args);
  await review(r.hub, key);
  assert.ok(!r.store.archiveSuggested(r.thread("C1", m.threadTs).id));
  server.close();
  await r.close();
});

test("turning the rule on reviews the done chats no decision has answered, once each", async (t) => {
  const r = new Rig();
  const m = say("<@UBOT> explain retention");
  await r.accept(m);
  await settle();
  const key = `cl:C1:${m.threadTs}`;
  const thread = () => r.thread("C1", m.threadTs).id;
  const { url, server } = await provider(true);
  t.after(() => server.close());
  installDecisionProfile(r, url);
  // Done while the rule was off: nothing looked at it.
  r.edit((raw) => (raw.automaticDecisions.completion.enabled = false));
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "It controls retention.", kind: "all_done", done: "Explained the setting" });
  r.claude.last().complete();
  await settle();
  await review(r.hub, key);
  assert.ok(!r.store.archiveSuggested(thread()));
  assert.equal(r.store.recentDecisions().length, 0);
  // Turned on: it is reviewed then, without the agent ending another turn.
  r.edit((raw) => (raw.automaticDecisions.completion.enabled = true));
  await reviewUndecided(r.hub);
  assert.ok(r.store.archiveSuggested(thread()));
  assert.equal(r.store.recentDecisions().length, 1);
  // A chat already answered as it stands is not asked about again.
  await reviewUndecided(r.hub);
  assert.equal(r.store.recentDecisions().length, 1);
  await r.close();
});

test("the archive policy decides by the option picked; an agent changing it is kept by its session and asks again", async (t) => {
  const r = new Rig();
  const m = say("<@UBOT> make the button blue, show me first");
  await r.accept(m);
  await settle();
  const key = `cl:C1:${m.threadTs}`;
  const thread = () => r.thread("C1", m.threadTs).id;
  const { url, server } = await provider(false);
  t.after(() => server.close());
  installDecisionProfile(r, url);
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "Branch blue-button is up for you to look at.", kind: "all_done", done: "The branch is pushed" });
  r.claude.last().complete();
  await settle();
  await review(r.hub, key);
  // Picked: awaiting review, which the default policy does not count as archive.
  assert.ok(!r.store.archiveSuggested(thread()));
  const decided = r.store.lastDecision(key);
  assert.deepEqual(decided.option, { id: "awaiting_review", name: "等人看结果", archive: false });
  assert.equal(decided.policyAt, 0);
  const [tool] = archiveTools(r.hub);
  const read = JSON.parse(await tool!.run(key, {}));
  assert.deepEqual(read, DEFAULT_POLICY);
  await assert.rejects(tool!.run(key, { options: [{ name: "只有一个", rubric: "", archive: true }] }), /2 到 20/);
  const options = read.options.map((o: Json) => (o.id === "awaiting_review" ? { ...o, archive: true } : o));
  const said = await tool!.run(key, { options });
  assert.match(said, /「等人看结果」改成推荐归档/);
  assert.equal(await tool!.run(key, { options }), "Nothing changed: the policy is already so.");
  const saved = r.store.archivePolicy()!;
  assert.deepEqual(saved.change.by, { kind: "agent", session: key });
  // Under the new policy the chat is asked about again, and now recommended.
  await reviewUndecided(r.hub);
  assert.ok(r.store.archiveSuggested(thread()));
  assert.equal(r.store.lastDecision(key).policyAt, saved.change.id);
  await r.close();
});

// ── the tools beside the hub's ──

test("station_* reach the transport, pretty-printed; adb_devices and feedback_send as the Rust says them", async () => {
  const calls: [string, string, Json][] = [];
  const tools = stationTools(() => ({
    tool: async (name, session, args) => {
      calls.push([name, session, args]);
      return { ok: true, stations: [] };
    },
    ask: async () => ({}),
    closeSession: () => {},
  }));
  assert.equal(await tools[0]!.run("s", {}), JSON.stringify({ ok: true, stations: [] }, null, 2));
  assert.deepEqual(calls, [["station_list", "s", {}]]);
  await assert.rejects(stationTools(() => null)[1]!.run("s", { station: "x", action: "list" }), /cannot be reached/);
  const page = "https://app.still.fail/w/w1/s/st1/adb";
  const none = await adbTools(() => [], () => page)[0]!.run("s", {});
  assert.ok(none.startsWith("No phone is shared") && none.includes(page));
  const one = await adbTools(() => [{ serial: "127.0.0.1:37123", adb: "connected" }], () => page)[0]!.run("s", {});
  assert.ok(one.includes("127.0.0.1:37123") && one.includes("adb -s <serial>") && one.includes("/s/st1/adb"));
  assert.ok(!(await adbTools(() => [], () => null)[0]!.run("s", {})).includes("http"));
  const r = new Rig();
  const [key] = newSession(r.hub, web("local"));
  const sent: Json[] = [];
  const feedback = feedbackTools(r.store, () => "https://x/o/1", () => async (report) => (sent.push(report), { number: 7 }))[0]!;
  assert.equal(await feedback.run(key, { to: "EMBER/1.1", title: "chat_post fails", body: "it said 500", area: "station", reporter: "Ada" }), "Sent to the still.fail team as FB-7.");
  assert.deepEqual([sent[0].area, sent[0].context.session, sent[0].context.thread, sent[0].context.link], ["station", key, "EMBER/1.1", "https://x/o/1"]);
  await assert.rejects(feedbackTools(r.store, () => null, () => null)[0]!.run(key, { title: "a", body: "b" }), /not connected to still.fail cloud/);
  await r.close();
});
