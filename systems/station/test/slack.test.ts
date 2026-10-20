// Slack as a chat surface (chat/slack.rs, chat/names.rs, chat/status.rs tests, ported), against a stand-in for Slack
// (test/slack-fake.ts): events taken from Socket Mode, the socket given up when it goes quiet, posting, history, the
// Web API as the bot, token checks, names kept on disk, and the status line in a thread.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { Clock, Effect, Exit, FiberSet, Option, Result, Scope } from "effect";
import { TestClock } from "effect/testing";
import type { ChatEvent } from "../src/sessions/chat.ts";
import { toolStatus } from "../src/sessions/chat.ts";
import { NameBook } from "../src/slack/names.ts";
import { ThreadStatus } from "../src/slack/status.ts";
import { SlackSurface, toEvent, verifySlackTokens } from "../src/slack/surface.ts";
import { SlackClient } from "../src/slack/web.ts";
import { settle, testClock } from "./hub-fakes.ts";
import { FakeSlack, bot } from "./slack-fake.ts";

const quiet = async (_: ChatEvent) => {};
const PING = 50;
const STALE = 200;

// Each test has its own stand-in for Slack, surface and files: they run side by side.
describe("slack", { concurrency: true }, () => {
  test("slack events become messages and edits, and the rest is left", () => {
    assert.deepEqual(toEvent({ type: "message", channel: "C1", user: "U1", ts: "2.1", thread_ts: "1.1", text: "hi <@UBOT>" }, "UBOT", "BBOT"), {
      type: "message",
      message: { channel: "C1", threadTs: "1.1", ts: "2.1", user: "U1", text: "hi <@UBOT>", addressed: true },
    });
    // A message of its own starts its thread; a direct message is addressed.
    const dm = toEvent({ type: "message", channel: "D1", channel_type: "im", user: "U1", ts: "3.1", text: "hey" }, "UBOT", "BBOT");
    assert.ok(dm?.type === "message" && dm.message.threadTs === "3.1" && dm.message.addressed);
    const plain = toEvent({ type: "message", channel: "C1", user: "U1", ts: "3.2", text: "chatter" }, "UBOT", "BBOT");
    assert.ok(plain?.type === "message" && !plain.message.addressed);
    const mention = toEvent({ type: "app_mention", channel: "C1", user: "U1", ts: "3.3", text: "yo" }, "UBOT", "BBOT");
    assert.ok(mention?.type === "message" && mention.message.addressed);
    assert.deepEqual(toEvent({ type: "message", subtype: "message_changed", channel: "C1", message: { ts: "2.1", thread_ts: "1.1", text: "new" } }, "UBOT", "BBOT"), {
      type: "changed",
      channel: "C1",
      threadTs: "1.1",
      ts: "2.1",
      text: "new",
    });
    for (const left of [
      { type: "message", subtype: "message_deleted", channel: "C1" },
      { type: "message", channel: "C1", user: "UBOT", ts: "1" },
      { type: "message", subtype: "channel_join", channel: "C1", user: "U1", ts: "1" },
      { type: "reaction_added" },
      { type: "message", subtype: "message_changed", channel: "C1", message: { ts: "2.1", user: "UBOT", text: "mine" } },
    ]) {
      assert.equal(toEvent(left, "UBOT", "BBOT"), null, JSON.stringify(left));
    }
    // Another app's bot is heard like a person (by its bot user, else its bot id); its own bot, by either, is not.
    const other = toEvent({ type: "message", channel: "C1", bot_id: "B2", user: "U2", ts: "4.1", text: "done" }, "UBOT", "BBOT");
    assert.ok(other?.type === "message" && other.message.user === "U2");
    const bare = toEvent({ type: "message", subtype: "bot_message", channel: "C1", bot_id: "B2", ts: "4.2", text: "hook" }, "UBOT", "BBOT");
    assert.ok(bare?.type === "message" && bare.message.user === "B2");
    assert.equal(toEvent({ type: "message", subtype: "bot_message", channel: "C1", bot_id: "BBOT", ts: "4.3" }, "UBOT", "BBOT"), null);
  });

  test("files shared with a message come with it, those Slack keeps back without an address", () => {
    const shared = toEvent(
      {
        type: "message",
        subtype: "file_share",
        channel: "C1",
        user: "U1",
        ts: "6.1",
        text: "<@UBOT> 看看",
        files: [
          { id: "F1", name: "image.png", size: 10, mode: "hosted", url_private: "https://files.slack.com/files-pri/T-F1/image.png", url_private_download: "https://files.slack.com/files-pri/T-F1/download/image.png" },
          { id: "F2", title: "doc", mode: "external", url_private: "https://docs.google.com/x" },
          { id: "F3", mode: "hidden_by_limit" },
        ],
      },
      "UBOT",
      "BBOT",
    );
    assert.ok(shared?.type === "message");
    assert.deepEqual(shared.message.files, [
      { id: "F1", name: "image.png", size: 10, url: "https://files.slack.com/files-pri/T-F1/download/image.png" },
      { id: "F2", name: "doc", size: 0, url: null },
      { id: "F3", name: "F3", size: 0, url: null },
    ]);
  });

  test("a shared file is read with the bot's token from Slack only, and a sign-in page is no file", async () => {
    const fake = await FakeSlack.start();
    try {
      const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base) });
      const at = (path: string) => fake.base.replace(/\/api$/, `/${path}`);
      fake.answer("F1/shot.png", { __status: 200, __headers: { "content-type": "image/png" }, __body: "png" });
      const bytes = await surface.download({ id: "F1", name: "shot.png", size: 5, url: at("F1/shot.png") });
      assert.equal(new TextDecoder().decode(bytes), '"png"');
      assert.equal(fake.calls("F1/shot.png")[0]!.auth, "xoxb-1");
      fake.answer("F2/shot.png", { __status: 200, __headers: { "content-type": "text/html" }, __body: "sign in" });
      await assert.rejects(surface.download({ id: "F2", name: "shot.png", size: 5, url: at("F2/shot.png") }), /files:read/);
      await assert.rejects(surface.download({ id: "F3", name: "x", size: 1, url: "https://evil.example/x" }), /not a Slack address/);
      await assert.rejects(surface.download({ id: "F4", name: "x", size: 1, url: null }), /does not give/);
      assert.equal(fake.calls("x").length, 0);
    } finally {
      await fake.close();
    }
  });

  test("tables in blocks and attachments are read with the text, as Markdown tables", () => {
    const link = (url: string, label: string) => ({ type: "rich_text", elements: [{ type: "rich_text_section", elements: [{ type: "link", url, text: label }] }] });
    const table = {
      type: "table",
      rows: [
        [link("https://github.com/o/r/pull/1", "o/r#1 · fix(chat): keep it"), { type: "raw_text", text: "Router 复用老 Task" }],
        [{ type: "raw_text", text: "a | b" }, { type: "rich_text", elements: [{ type: "rich_text_section", elements: [{ type: "user", user_id: "U9" }, { type: "text", text: " line\nnext" }] }] }],
      ],
    };
    const table_md = "| <https://github.com/o/r/pull/1|o/r#1 · fix(chat): keep it> | Router 复用老 Task |\n| --- | --- |\n| a \\| b | <@U9> line next |";
    // As Slack's composer sends one: the table in an attachment, the text without it.
    const composed = toEvent({ type: "app_mention", channel: "C1", user: "U1", ts: "5.1", text: "<@UBOT> review & merge", attachments: [{ blocks: [table] }] }, "UBOT", "BBOT");
    assert.ok(composed?.type === "message");
    assert.equal(composed.message.text, `<@UBOT> review & merge\n\n${table_md}`);
    // As an app posts one: in the blocks, beside the rich text the text already says.
    const posted = toEvent({ type: "message", channel: "C1", user: "U1", ts: "5.2", text: "see", blocks: [{ type: "rich_text", elements: [] }, table] }, "UBOT", "BBOT");
    assert.ok(posted?.type === "message" && posted.message.text === `see\n\n${table_md}`);
    const edited = toEvent({ type: "message", subtype: "message_changed", channel: "C1", message: { ts: "5.1", text: "", blocks: [table] } }, "UBOT", "BBOT");
    assert.ok(edited?.type === "changed" && edited.text === table_md);
  });

  test("tokens must be of their kind", () => {
    assert.throws(() => new SlackSurface({ appToken: "xoxb-1", botToken: "xoxb-1" }), /app-level token/);
    assert.throws(() => new SlackSurface({ appToken: "xapp-1", botToken: "xapp-1" }), /bot token/);
  });

  test("a socket that goes quiet is given up; one that answers pings stays", async () => {
    // The station's own ping and staleness (5 s, 20 s), on a clock of the test's: only pings (and pongs) are real.
    const PING_MS = 5_000;
    const STALE_MS = 20_000;
    const scope = Effect.runSync(Scope.make());
    const fake = await FakeSlack.start();
    try {
      const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
      let heard = 0;
      /// Moves the clock a ping on, until `done`: each time once the surface's look came to its end (or a ping it sent
      /// came, and when the stand-in answers pings, its pong came back), so the surface is waiting for its next.
      const ping = async (done: () => boolean) => {
        while (!done()) {
          const [pings, pongs] = [fake.pings, heard];
          await Effect.runPromise(clock.adjust(PING_MS));
          await fake.until("a ping, or the end", () => done() || (fake.pings > pings && (!fake.answersPings || heard > pongs)));
        }
      };

      fake.answersPings = false;
      const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base), clock });
      const started = clock.currentTimeMillisUnsafe();
      let failed: Error | undefined;
      void Effect.runPromise(Effect.flip(surface.runSocket(fake.socketUrl(), quiet))).then((e) => (failed = e));
      await fake.until("a socket", () => surface.socket().connected);
      // Its watch goes on from the socket's opening to its first wait.
      await settle();
      await ping(() => failed !== undefined);
      const took = clock.currentTimeMillisUnsafe() - started;
      assert.match(failed!.message, /said nothing/);
      assert.ok(took >= STALE_MS && took < STALE_MS * 3, `${took} ms`);

      fake.answersPings = true;
      const staying = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base), clock, onHeard: () => heard++ });
      // Nothing but pongs comes in, for well past its staleness: still up.
      let raced: Result.Result<Option.Option<void>, Error> | undefined;
      const running = Effect.timeoutOption(staying.runSocket(fake.socketUrl(), quiet), STALE_MS * 6).pipe(Effect.provideService(Clock.Clock, clock));
      void Effect.runPromise(Effect.result(running)).then((r) => (raced = r));
      await fake.until("a second socket", () => fake.sockets.length === 2 && staying.socket().connected);
      await settle();
      await ping(() => raced !== undefined);
      assert.ok(Result.isSuccess(raced!) && Option.isNone(raced.success), "still running when the time was up");
      assert.ok(fake.pings >= 6 * (STALE_MS / PING_MS) - 1, `pinged ${fake.pings} times`);
      assert.ok(staying.socket().connected);
    } finally {
      await fake.close();
      await Effect.runPromise(Scope.close(scope, Exit.void));
    }
  });

  test("a connected surface takes Socket Mode events, acknowledges those it kept, reconnects when asked, and stops", async () => {
    const fake = await FakeSlack.start();
    bot(fake);
    // The connections it asks Slack for, counted as it asks.
    const client = new SlackClient(fake.base);
    const api = client.api.bind(client);
    let opens = 0;
    client.api = ((method: string, ...rest: unknown[]) => {
      if (method === "apps.connections.open") opens++;
      return (api as any)(method, ...rest);
    }) as typeof client.api;
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client, pingMs: PING, staleMs: STALE * 5 });
    const heard: ChatEvent[] = [];
    let changes = 0;
    surface.onChange(() => changes++);
    try {
      await surface.start(async (event) => {
        if (event.type === "message" && event.message.text === "refuse") throw new Error("not kept");
        heard.push(event);
      });
      assert.deepEqual([surface.botUserId(), surface.botName(), surface.workspace()], ["UBOT", "ember", "T1"]);
      assert.equal(surface.identity()!.botImage, "https://avatars.slack-edge.com/ember_72.png");
      await fake.until("a socket", () => fake.sockets.length === 1 && surface.socket().connected);
      assert.equal(fake.calls("apps.connections.open")[0]!.auth, "xapp-1");
      fake.event("e1", { type: "app_mention", channel: "C1", user: "U1", ts: "5.1", text: "<@UBOT> hi" });
      fake.event("e2", { type: "message", channel: "C1", user: "UBOT", ts: "5.2", text: "mine" });
      fake.event("e3", { type: "message", channel: "C1", user: "U1", ts: "5.3", text: "refuse" });
      // Taken after e3 was (each event's handler ends before the next is read here): its ack comes after any of e3's.
      fake.event("e4", { type: "message", channel: "C1", user: "UBOT", ts: "5.4", text: "mine again" });
      fake.send({ type: "hello" });
      await fake.until("e4's ack", () => fake.acks.some((a) => a.envelope_id === "e4"));
      assert.deepEqual(
        fake.acks.map((a) => a.envelope_id).sort(),
        ["e1", "e2", "e4"],
        "what it kept, and what it ignores, acknowledged; what failed is not (Slack sends it again)",
      );
      assert.deepEqual(heard, [{ type: "message", message: { channel: "C1", threadTs: "5.1", ts: "5.1", user: "U1", text: "<@UBOT> hi", addressed: true } }]);
      // Slack rotates connections: asked to, it connects again.
      fake.send({ type: "disconnect", reason: "refresh_requested" });
      await fake.until("a second socket", () => fake.sockets.length === 2 && surface.socket().connected);
      assert.ok(changes >= 3, "the socket's ups and downs are told");
      await surface.stop();
      await fake.until("the socket closed", () => fake.sockets[1]!.readyState === fake.sockets[1]!.CLOSED);
      await settle();
      assert.deepEqual([opens, fake.sockets.length], [2, 2], "stopped: not connected again");
    } finally {
      await surface.stop();
      await fake.close();
    }
  });

  test("a socket that fails is tried again later, its error said", async () => {
    const fake = await FakeSlack.start();
    bot(fake);
    let opens = 0;
    fake.answer("apps.connections.open", () => (++opens === 1 ? { ok: false, error: "invalid_auth" } : { ok: true, url: fake.socketUrl() }));
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base), pingMs: PING, staleMs: STALE * 5 });
    try {
      const states: string[] = [];
      surface.onChange(() => states.push(`${surface.socket().connected}:${surface.socket().lastError}`));
      // A short first wait, for the test: the station's is a second.
      (surface as any).backoffMs = 30;
      await surface.start(quiet);
      await fake.until("connected after a failure", () => surface.socket().connected);
      assert.deepEqual(states, ["false:slack apps.connections.open: invalid_auth", "true:null"]);
    } finally {
      await surface.stop();
      await fake.close();
    }
  });

  test("posts go out as written, a long one in parts; files are uploaded first and shared below the text", async () => {
    const fake = await FakeSlack.start();
    bot(fake);
    const dir = mkdtempSync(join(tmpdir(), "sl-"));
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base) });
    try {
      const thread = { channel: "C1", threadTs: "1.1" };
      const ts = await surface.post(thread, "*hello* <https://x|x>", []);
      const first = fake.calls("chat.postMessage")[0]!;
      assert.deepEqual(first.params, { channel: "C1", thread_ts: "1.1", text: "*hello* <https://x|x>", unfurl_links: "false" });
      assert.equal(first.auth, "xoxb-1");
      assert.equal(ts, "8000001.000100");
      const para = "y".repeat(2000);
      const long = await surface.post(thread, `${para}\n\n${para}`, []);
      assert.equal(fake.calls("chat.postMessage").length, 3);
      assert.equal(long, "8000002.000100", "the first part's ts stands for the whole");
      await assert.rejects(surface.post(thread, "", []), /nothing to post/);

      // Files: the bytes to the address Slack gives, then shared in the thread; with no text, the share's ts.
      const file = join(dir, "shot.png");
      writeFileSync(file, "PNGDATA");
      const uploads: string[] = [];
      fake.answer("files.getUploadURLExternal", { ok: true, upload_url: `${fake.base}/upload-here`, file_id: "F1" });
      fake.answer("upload-here", (s) => (uploads.push(s.body), { ok: true }));
      fake.answer("files.completeUploadExternal", { ok: true, files: [{ id: "F1", shares: { public: { C1: [{ ts: "9.9" }] } } }] });
      assert.equal(await surface.post(thread, "", [{ name: "shot.png", path: file, size: 7 }]), "9.9");
      assert.deepEqual(fake.calls("files.getUploadURLExternal")[0]!.params, { filename: "shot.png", length: "7" });
      assert.deepEqual(uploads, ["PNGDATA"]);
      const shared = fake.calls("files.completeUploadExternal")[0]!.params;
      assert.deepEqual([JSON.parse(shared.files!), shared.channel_id, shared.thread_ts], [[{ id: "F1", title: "shot.png" }], "C1", "1.1"]);
      // An app without files:write: nothing is said.
      fake.answer("files.getUploadURLExternal", { ok: false, error: "missing_scope" });
      const before = fake.calls("chat.postMessage").length;
      await assert.rejects(surface.post(thread, "with a file", [{ name: "shot.png", path: file, size: 7 }]), /slack files.getUploadURLExternal: missing_scope/);
      assert.equal(fake.calls("chat.postMessage").length, before);
    } finally {
      await fake.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("history pages through the thread and gives what came before, the latest at most; people and channels are named", async () => {
    const fake = await FakeSlack.start();
    bot(fake);
    fake.answer("conversations.replies", (s) =>
      s.params.cursor === undefined
        ? { ok: true, messages: [{ ts: "1.1", user: "U1", text: "a" }, { ts: "1.2", bot_id: "B9", text: "b", attachments: [{ blocks: [{ type: "table", rows: [[{ type: "raw_text", text: "k" }], [{ type: "raw_text", text: "v" }]] }] }] }], response_metadata: { next_cursor: "c2" } }
        : { ok: true, messages: [{ ts: "1.3", user: "UBOT", text: "c" }, { ts: "1.4", user: "U2", text: "d" }] },
    );
    fake.answer("conversations.info", (s) => (s.params.channel === "D1" ? { ok: true, channel: { id: "D1", is_im: true } } : { ok: true, channel: { id: "C1", name: "general" } }));
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base) });
    try {
      await surface.start(quiet);
      const earlier = await surface.history({ channel: "C1", threadTs: "1.1" }, "1.4", 2);
      assert.deepEqual(earlier, [
        { ts: "1.2", user: "B9", text: "b\n\n| k |\n| --- |\n| v |", fromBot: true },
        { ts: "1.3", user: "UBOT", text: "c", fromBot: true },
      ]);
      assert.deepEqual(fake.calls("conversations.replies").map((c) => c.params.cursor ?? null), [null, "c2"]);
      assert.deepEqual([await surface.userName("U1"), await surface.userEmail("U1")], ["Ada", "ada@example.test"]);
      assert.equal(fake.calls("users.info").filter((c) => c.params.user === "U1").length, 1, "asked once for the connection's lifetime");
      assert.deepEqual([await surface.channelName("C1"), await surface.channelName("D1"), await surface.channelName("C1")], ["general", null, "general"]);
      assert.equal(fake.calls("conversations.info").length, 2);
    } finally {
      await surface.stop();
      await fake.close();
    }
  });

  test("any Web API method as the bot: structures go as JSON, nulls left out; Slack's refusal and its 429 waits", async () => {
    const fake = await FakeSlack.start();
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base) });
    try {
      await surface.api("chat.postMessage", { channel: "C1", blocks: [{ type: "section" }], unfurl: false, limit: 3, skip: null });
      assert.deepEqual(fake.calls("chat.postMessage")[0]!.params, { channel: "C1", blocks: '[{"type":"section"}]', unfurl: "false", limit: "3" });
      fake.answer("reactions.add", { ok: false, error: "already_reacted" });
      await assert.rejects(surface.api("reactions.add", {}), { message: "slack reactions.add: already_reacted" });
      fake.answer("pins.add", { ok: false });
      await assert.rejects(surface.api("pins.add", {}), { message: "slack pins.add: undefined" });
      let tries = 0;
      fake.answer("users.list", () => (++tries === 1 ? { __status: 429, __headers: { "retry-after": "0" }, __body: { ok: false, error: "ratelimited" } } : { ok: true, members: [] }));
      assert.deepEqual(await surface.api("users.list", {}), { ok: true, members: [] });
      assert.equal(tries, 2);
    } finally {
      await fake.close();
    }
  });

  test("a token pair is checked without connecting: the bot's identity, or what is wrong with each", async () => {
    const fake = await FakeSlack.start();
    bot(fake, { name: "helper" });
    const client = new SlackClient(fake.base);
    try {
      const [identity, errors] = await verifySlackTokens(client, "xapp-1", "xoxb-1", "zh");
      assert.deepEqual(errors, []);
      assert.deepEqual(identity, { team: "Acme", teamId: "T1", url: "https://acme.slack.com/", botUserId: "UBOT", botName: "helper", botImage: "https://avatars.slack-edge.com/ember_72.png", botId: "BBOT" });
      const [none, wrong] = await verifySlackTokens(client, "xoxb-2", "xapp-2", "zh");
      assert.equal(none, null);
      assert.deepEqual(wrong, ["Bot Token 应该以 xoxb- 开头", "App-Level Token 应该以 xapp- 开头"]);
      fake.answer("auth.test", { ok: false, error: "invalid_auth" });
      fake.answer("apps.connections.open", { ok: false, error: "not_allowed_token_type" });
      const [, refused] = await verifySlackTokens(client, "xapp-1", "xoxb-1", "en");
      assert.equal(refused.length, 2);
      assert.match(refused[0]!, /slack auth\.test: invalid_auth/);
      assert.match(refused[1]!, /slack apps\.connections\.open: not_allowed_token_type/);
    } finally {
      await fake.close();
    }
  });

  test("a name not known yet is fetched once, kept and told", async () => {
    const dir = mkdtempSync(join(tmpdir(), "nb-"));
    const path = join(dir, "slack-names.json");
    try {
      const time = testClock();
      const book = new NameBook(path, { learnAfterMs: 20, saveAfterMs: 60, clock: time.clock });
      let told = 0;
      let asked = 0;
      book.onLearn(() => told++);
      const ada = async () => (asked++, { name: "Ada", email: "ada@x" });
      assert.equal(book.person("u:T:U1", ada), null);
      assert.equal(book.person("u:T:U1", ada), null, "asked again while fetching: not twice");
      assert.equal(book.channel("c:T:D1", async () => null), null);
      assert.equal(book.person("u:T:U9", async () => null), null);
      await settle();
      assert.equal(asked, 1);
      assert.equal(book.person("u:T:U1", ada)?.name, "Ada");
      assert.equal(told, 0, "told once the burst is over");
      await time.adjust(20);
      await settle();
      assert.equal(told, 1, "once per burst");
      // A failed lookup is not tried again for a while.
      let again = 0;
      book.person("u:T:U9", async () => (again++, null));
      await settle();
      assert.equal(again, 0);
      await book.close();
      // Kept on disk: a direct message known to have no name, and the person.
      const kept = JSON.parse(readFileSync(path, "utf8"));
      assert.equal(kept["c:T:D1"].channel, null);
      const reopened = new NameBook(path);
      assert.equal(reopened.person("u:T:U1", ada)?.email, "ada@x");
      assert.equal(reopened.channel("c:T:D1", async () => "never"), null);
      await reopened.close();
      // A broken file: starting empty.
      writeFileSync(path, "{nope");
      const broken = new NameBook(path);
      assert.equal(broken.person("u:T:U1", async () => null), null);
      await broken.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  type Calls = [string, Record<string, string>][];
  function recording(fail: string | null): [(method: string, params: [string, string][]) => Promise<void>, Calls] {
    const calls: Calls = [];
    return [
      async (method, params) => {
        calls.push([method, Object.fromEntries(params)]);
        if (fail !== null && method === "assistant.threads.setStatus") throw new Error(`slack assistant.threads.setStatus: ${fail}`);
      },
      calls,
    ];
  }
  /// Runs a status line's waits as fibers of a scope the test closes: a wait still due (the next change, seconds on) ends
  /// with it, and does not hold the test's process.
  /// On a TestClock, moved on by `adjust`.
  function fibers(): { run: (effect: Effect.Effect<void>) => Promise<void>; adjust: (ms: number) => Promise<void>; close: () => Promise<void> } {
    const scope = Effect.runSync(Scope.make());
    const time = testClock();
    const runtime = Effect.runSync(Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), scope));
    const run = (effect: Effect.Effect<void>) => runtime(effect.pipe(Effect.provideService(Clock.Clock, time.clock)));
    return { run, adjust: time.adjust, close: () => Effect.runPromise(Scope.close(scope, Exit.void)) };
  }

  test("a thread's status line says what the agent does and goes when it is done", async (t) => {
    const { run, adjust, close } = fibers();
    t.after(close);
    const [call, calls] = recording(null);
    const line = new ThreadStatus(call, run, "C1", "1.1");
    line.say("正在思考…", "1.2");
    await settle();
    line.say("", null);
    await settle();
    assert.deepEqual(
      calls.map(([m, p]) => [m, p.status]),
      [
        ["assistant.threads.setStatus", "正在思考…"],
        ["assistant.threads.setStatus", ""],
      ],
    );
    assert.deepEqual([calls[0]![1].channel_id, calls[0]![1].thread_ts, calls[0]![1].loading_messages], ["C1", "1.1", "正在思考…"]);
    // Changed at most every couple of seconds: what is said meanwhile waits, and only the latest goes.
    const [paced, sent] = recording(null);
    const busy = new ThreadStatus(paced, run, "C1", "1.1");
    busy.say("a", null);
    await settle();
    await adjust(20);
    busy.say("b", null);
    busy.say("c", null);
    await adjust(1_000);
    await settle();
    assert.deepEqual(sent.map(([, p]) => p.status), ["a"]);
    await adjust(980);
    await settle();
    assert.deepEqual(sent.map(([, p]) => p.status), ["a", "c"]);
  });

  test("where Slack will not show a status, an eyes reaction stands in", async (t) => {
    const { run, close } = fibers();
    t.after(close);
    const [call, calls] = recording("missing_scope");
    const line = new ThreadStatus(call, run, "C1", "1.1");
    line.say("正在运行命令…", "1.2");
    await settle();
    line.say("", null);
    await settle();
    assert.deepEqual(
      calls.map(([m, p]) => [m, p.timestamp ?? null, p.name ?? null]),
      [
        ["assistant.threads.setStatus", null, null],
        ["reactions.add", "1.2", "eyes"],
        ["reactions.remove", "1.2", "eyes"],
      ],
    );
  });

  test("tool calls in words, by either runtime's names", () => {
    const words = ["Read", "Bash", "exec_command", "apply_patch", "WebSearch", "mcp__ember__chat_post", "something"].map(toolStatus);
    assert.deepEqual(words, ["正在查看文件…", "正在运行命令…", "正在运行命令…", "正在修改文件…", "正在搜索网页…", "正在看 Slack…", "正在处理…"]);
  });

  test("a surface's status line goes to Slack as the bot", async () => {
    const fake = await FakeSlack.start();
    const surface = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(fake.base) });
    try {
      surface.working({ channel: "C1", threadTs: "1.1" }, "1.2", "正在思考…");
      await fake.until("a status", () => fake.calls("assistant.threads.setStatus").length === 1);
      assert.deepEqual(fake.calls("assistant.threads.setStatus")[0]!.params, { channel_id: "C1", thread_ts: "1.1", status: "正在思考…", loading_messages: "正在思考…" });
      assert.equal(fake.calls("assistant.threads.setStatus")[0]!.auth, "xoxb-1");
    } finally {
      await surface.stop();
      await fake.close();
    }
  });
});
