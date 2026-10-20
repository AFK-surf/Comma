// End to end through Slack's stand-in (test/slack-fake.ts), with the real Claude driver under the real runner (studio
// only: the runner is a native build) and the fake `claude` (test/fake): an app_mention comes down the Socket Mode
// socket, the connect's surface hands it to the hub, a turn starts; the agent calls chat_post through the MCP endpoint;
// the post goes out as chat.postMessage into the Slack thread, the event is acknowledged, and the turn ends all_done.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { ClaudeDriver } from "../src/agents/claude.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { makeConnections } from "../src/slack/index.ts";
import { SlackClient } from "../src/slack/web.ts";
import { chatTools } from "../src/tools/chat.ts";
import { openAgentsDoor } from "../src/tools/http.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { Store } from "../src/store/store.ts";
import { settle } from "./hub-fakes.ts";
import { FakeSlack, bot } from "./slack-fake.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;

test("an app_mention over Socket Mode starts a turn; the agent's chat_post lands in the Slack thread as chat.postMessage", async () => {
  // Short: the runners' sockets live under it (104 bytes at most on macOS).
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "se-") : "/tmp/se-");
  const home = join(data, "homes", "cc");
  mkdirSync(home, { recursive: true });
  // A login in its file: nothing is looked for in the keychain.
  writeFileSync(join(home, ".credentials.json"), "{}");
  delete process.env.STILLFAIL_CONFIG;
  delete process.env.EMBER_CONFIG;
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
      maxNudges: 1,
      connects: [{ id: "ds", mode: "multi-session", bind: { runtime: "claude" }, slack: { appToken: "xapp-1-e2e", botToken: "xoxb-e2e" } }],
    }),
  );
  const slackStandIn = await FakeSlack.start();
  bot(slackStandIn);
  const config = new ConfigFile(data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const driver = new ClaudeDriver({ data });
  let url = "";
  let hub: Hub | undefined;
  // The surface's own timing (its status line's pace, its pings) on a clock of the test's.
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const slack = makeConnections({ data, store, config, receive: (id, event) => hub!.receive(id, event), bound: () => true, client: new SlackClient(slackStandIn.base), clock });
  hub = new Hub({ config: () => hubConfig(config.raw(), data), store, chats: slack.chats, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  try {
    await slack.reconcile();
    await slackStandIn.until("connected", () => slack.state("ds")?.state === "connected");
    slackStandIn.event("env-1", { type: "app_mention", channel: "C1", user: "U42", ts: "1700000000.000100", text: "<@UBOT> post:hello from the agent" });
    // Kept, then acknowledged.
    await slackStandIn.until("acknowledged", () => slackStandIn.acks.some((a) => a.envelope_id === "env-1"));
    const key = "ds:C1:1700000000.000100";
    assert.ok(store.getSession(key), "its session made");
    // Its turn: started, posted, ended.
    await slackStandIn.until("posted", () => slackStandIn.calls("chat.postMessage").length > 0);
    // Real processes: looked at every 25 ms (no deadline).
    while (store.lastTurn(key)?.endedAt == null) await new Promise((r) => setTimeout(r, 25));
    const posts = slackStandIn.calls("chat.postMessage");
    assert.equal(posts.length, 1, JSON.stringify(posts.map((p) => p.params)));
    assert.deepEqual(posts[0]!.params, { channel: "C1", thread_ts: "1700000000.000100", text: "hello from the agent", unfurl_links: "false" });
    assert.equal(posts[0]!.auth, "xoxb-e2e");
    // Recorded in the thread once Slack took it, under the ts Slack gave it.
    const thread = store.threadAt("slack:T1", "C1", "1700000000.000100")!;
    const said = store.messagesBefore(thread.id, null, 10).map((m) => [m.authorKind, m.author, m.text, m.ts]);
    assert.deepEqual(said, [
      ["person", "U42", "<@UBOT> post:hello from the agent", "1700000000.000100"],
      ["agent", key, "hello from the agent", "8000001.000100"],
    ]);
    const turns = store.listTurns(key);
    assert.equal(turns.length, 1, "not nudged");
    assert.deepEqual([turns[0]!.summary.outcome, turns[0]!.summary.ending], ["completed", "all_done"]);
    // While it worked, the thread said so, and the line was cleared at the end: at once, or (the line changed just
    // before) once its couple of seconds are up: what was due by then has gone.
    const cleared = () => slackStandIn.calls("assistant.threads.setStatus").some((c) => c.params.status === "");
    await settle();
    await Effect.runPromise(clock.adjust("2 seconds"));
    await slackStandIn.until("the status cleared", cleared);
    assert.equal(slackStandIn.calls("assistant.threads.setStatus")[0]!.params.thread_ts, "1700000000.000100");
  } finally {
    await slack.close();
    await hub.shutdown();
    await served.close(1000);
    store.close();
    await slackStandIn.close();
    await Effect.runPromise(Scope.close(scope, Exit.void));
    rmSync(data, { recursive: true, force: true });
  }
});
