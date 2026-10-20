// End to end, with the real Claude driver under the real runner (studio only: the runner is a native build) and the
// fake `claude` (test/fake): a message in the station's own chat starts a turn; the agent calls chat_post through the
// MCP endpoint over HTTP (src/tools/http.ts) with its session's token; the post is recorded in the chat; the turn
// ends all_done, not nudged.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { ClaudeDriver } from "../src/agents/claude.ts";
import { runnerId } from "../src/agents/process.ts";
import { runnersDir } from "../src/agents/runner.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { chatTools } from "../src/tools/chat.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { openAgentsDoor } from "../src/tools/http.ts";
import { Store } from "../src/store/store.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;

test("a message in the station's chat: a turn starts, the agent posts through the MCP endpoint, the turn ends all_done", () => turnRuns(false));

// The shape of a Cloud VM woken on a disk that kept another Container's runner record (or a desktop after a restart):
// the record names a pid that is some other process's now, and no runner is behind it.
test("a session whose runner's record names a pid another process has now: its turn starts all the same", () => turnRuns(true));

async function turnRuns(staleRecord: boolean) {
  // Short: the runners' sockets live under it (104 bytes at most on macOS).
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "he-") : "/tmp/he-");
  const home = join(data, "homes", "cc");
  mkdirSync(home, { recursive: true });
  // A login in its file: nothing is looked for in the keychain.
  writeFileSync(join(home, ".credentials.json"), "{}");
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  const driver = new ClaudeDriver({ data });
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  try {
    assert.deepEqual(await (await fetch(url.replace(/\/mcp$/, "/health"))).json(), { ok: true });
    const [key, thread] = newSession(hub, { runtime: "claude", createdBy: "ada@x.com" });
    if (staleRecord) {
      const at = (ext: string) => join(runnersDir(data), `${runnerId("claude", key)}.${ext}`);
      mkdirSync(runnersDir(data), { recursive: true });
      writeFileSync(at("json"), JSON.stringify({ id: runnerId("claude", key), runner: process.pid, pid: process.pid, pgid: process.pid, startedAt: 1, program: "claude", args: [], socket: at("sock"), out: at("out"), err: at("err") }) + "\n");
    }
    say(hub, thread.id, "ada@x.com", "post:hello from the agent");
    // Its turn: started, posted, ended.
    // Real processes: looked at every 25 ms (no deadline), until the turn is over or the station says none started.
    const told = () => store.messagesBefore(thread.id, null, 10).some((m) => m.authorKind === "ember");
    while (store.lastTurn(key)?.endedAt == null && !told()) await new Promise((r) => setTimeout(r, 25));
    const said = store.messagesBefore(thread.id, null, 10).map((m) => [m.authorKind, m.author, m.text]);
    assert.deepEqual(said, [
      ["person", "ada@x.com", "post:hello from the agent"],
      ["agent", key, "hello from the agent"],
    ]);
    const turns = store.listTurns(key);
    assert.equal(turns.length, 1, "not nudged");
    assert.deepEqual([turns[0]!.summary.outcome, turns[0]!.summary.ending, turns[0]!.summary.need], ["completed", "all_done", "answered the question that was asked"]);
    assert.ok(!store.getSession(key)!.running);
    assert.deepEqual(store.pendingMessages(key), []);
  } finally {
    await hub.shutdown();
    await served.close(1000);
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
}
