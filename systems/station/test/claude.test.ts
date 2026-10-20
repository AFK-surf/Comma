// The Claude Code driver (src/agents/claude.ts) against a fake claude (test/fake/claude: stream-json as the CLI writes
// it) under the real runner: turns, failures and how they are told apart, abort, steer, a turn of its own, the process
// exiting, background_tools, what it is started with, and a session taken up by a next driver (with a snapshot, and
// after a crash) with its turn's end told once and no live event twice.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { ClaudeDriver, classifyResult } from "../src/agents/claude.ts";
import { existingRunners } from "../src/agents/runner.ts";
import type { AgentSession, OpenOptions, RuntimeEvent } from "../src/agents/runtime.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;
// Inherited, and not to reach the agent.
process.env.CLAUDECODE = "1";
process.env.CLAUDE_CODE_OAUTH_TOKEN = "leaked";
// Short: the runners' sockets live under it (104 bytes at most on macOS).
const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "cl-") : "/tmp/cl-");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `done` holds: what real processes do has no event here. No deadline (it comes, however
/// slow the machine, or the test hangs).
async function eventually(done: () => boolean | Promise<boolean>) {
  while (!(await done())) await sleep(20);
}
/// The fifos a `gate:<n>:<k>:<name>` turn waits at (test/fake/claude.mjs): `open(part)` lets it go on.
function gates(dump: string, name: string) {
  const at = `${dump}.${name}`;
  if (process.platform !== "win32") for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${at}.${part}`]);
  return { open: (part: "a" | "b") => writeFile(`${at}.${part}`, "go"), said: () => existsSync(`${at}.said`) };
}
const drivers: ClaudeDriver[] = [];
after(async () => {
  await Promise.all(drivers.map((d) => d.shutdown()));
  rmSync(data, { recursive: true, force: true });
});

function driver(machineToken?: () => Promise<{ token: string; expiresAt: number }>) {
  const d = new ClaudeDriver({ data, machineToken });
  drivers.push(d);
  return d;
}

let n = 0;
function options(extra: Partial<OpenOptions> & { machine?: boolean } = {}): OpenOptions & { dump: string } {
  const i = ++n;
  const home = join(data, `h${i}`);
  mkdirSync(home, { recursive: true });
  // A login in its file: nothing is looked for in the keychain.
  writeFileSync(join(home, ".credentials.json"), "{}");
  const dump = join(data, `dump${i}`);
  const { machine, ...rest } = extra;
  return {
    key: `slack:T1:C${i}:1700000000.000${i}`,
    profile: { id: "cc", runtime: "claude", home, ...(machine ? { credential: "machine", source: "claude" } : { credential: "api_key", source: "opencode-go", key: "k1" }), env: { FAKE_DUMP: dump } },
    cwd: data,
    instructions: "be brief",
    mcpToken: "tok",
    mcpUrl: "http://127.0.0.1:4750/mcp",
    route: `route${i}`,
    dump,
    ...rest,
  };
}

function listen() {
  const events: RuntimeEvent[] = [];
  const push = (e: RuntimeEvent) => void events.push(e);
  const until = (what: (events: RuntimeEvent[]) => boolean) => eventually(() => what(events));
  return { events, push, until };
}

const ends = (events: RuntimeEvent[]) => events.filter((e) => e.type === "turnEnded");
const ended = (k: number) => (events: RuntimeEvent[]) => ends(events).length >= k;
const deltas = (events: RuntimeEvent[]) => events.flatMap((e) => (e.type === "live" && e.event.kind === "delta" ? [e.event.text] : []));
const outcome = (events: RuntimeEvent[], k = 0) => (ends(events)[k] as Extract<RuntimeEvent, { type: "turnEnded" }>).outcome;
const stdin = (dump: string) => readFileSync(`${dump}.stdin`, "utf8").trim().split("\n").map((l) => JSON.parse(l));

// Each test has its own driver, profile and runners: they run side by side.
describe("the Claude Code driver", { concurrency: true }, () => {
  test("a turn completes, from a process started with the flags and environment of claude.rs", async () => {
    const d = driver();
    const o = options({ model: "m1", effort: "high" });
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    assert.match(session.id(), /^[0-9a-f-]{36}$/);
    await session.prompt("say:hello");
    assert.equal(session.busy(), true);
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.equal(session.busy(), false);
    assert.ok(!events.some((e) => e.type === "turnStarted"), "our own prompt's turn is not one started without us");
    const live = events.flatMap((e) => (e.type === "live" ? [e.event] : []));
    assert.deepEqual(live.filter((e) => e.kind !== "phase").map((e) => e.kind), ["start", "delta", "end"]);
    assert.deepEqual(live.filter((e) => e.kind === "phase").map((e) => (e as { phase: string }).phase), ["requesting", "responding", "working"]);
    assert.deepEqual(deltas(events), ["hello"]);

    const started = JSON.parse(readFileSync(o.dump, "utf8").trim());
    const mcp = JSON.stringify({ mcpServers: { stillfail: { type: "http", url: o.mcpUrl, headers: { Authorization: "Bearer ${STILLFAIL_MCP_TOKEN}" } } } });
    assert.deepEqual(started.argv, [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      "--dangerously-skip-permissions", "--session-id", session.id(), "--model", "m1", "--effort", "high",
      "--append-system-prompt", "be brief", "--mcp-config", mcp,
    ]);
    const env = started.env;
    assert.equal(env.CLAUDE_CONFIG_DIR, o.profile.home);
    assert.equal(env.STILLFAIL_MCP_TOKEN, "tok");
    assert.equal(env.STILLFAIL_RUNTIME_SESSION_ID, session.id());
    assert.equal(env.EMBER_RUNTIME_SESSION_ID, session.id());
    assert.equal(env.CLAUDE_CODE_CERT_STORE, "bundled");
    assert.equal(env.CLAUDE_CODE_SILENT_TURN_REMINDER, "0");
    assert.equal(env.CLAUDECODE, undefined);
    assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, undefined, "not a profile's own");
    // OpenCode Go's access, its route the session's.
    assert.equal(env.ANTHROPIC_BASE_URL, "https://opencode.ai/zen/go");
    assert.equal(env.ANTHROPIC_API_KEY, "k1");
    assert.equal(env.ANTHROPIC_CUSTOM_HEADERS, `x-opencode-session: ${o.route}`);
    assert.equal(env.ANTHROPIC_SMALL_FAST_MODEL, "deepseek-flash");
    if (process.platform === "darwin") assert.match(env.PATH.split(":")[0], /stillfail-no-keychain-\d+$/, "a security that holds nothing of Claude Code's");

    // The user's message, as stream-json input.
    assert.deepEqual(stdin(o.dump)[0], { type: "user", message: { role: "user", content: [{ type: "text", text: "say:hello" }] } });
    await assert.rejects(session.prompt("x").then(() => session.prompt("y")), /a turn is already running/);
    await until(ended(2));
    await session.dispose();
    await until((e) => e.some((x) => x.type === "closed"));
  });

  test("a failed result is told apart by what claude said; is_error decides, not subtype", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    for (const [i, prompt] of ["fail:auth", "fail:rate", "fail:model", "say:You've hit your weekly limit"].entries()) {
      await session.prompt(prompt);
      await until(ended(i + 1));
    }
    assert.deepEqual(outcome(events, 0), { kind: "failed", reason: "auth", message: "API Error: 401 invalid x-api-key" });
    assert.deepEqual(outcome(events, 1), { kind: "failed", reason: "rate_limit", message: "You've hit your weekly limit · resets Oct 8" });
    assert.deepEqual(outcome(events, 2), { kind: "failed", reason: "model", message: "prompt is too long" });
    assert.deepEqual(outcome(events, 3), { kind: "completed" }, "a successful text saying a limit is no failure");
    assert.equal(classifyResult("Claude AI usage limit reached"), "rate_limit");
    assert.equal(classifyResult("session limit configuration is invalid"), "model");
    await session.dispose();
  });

  test("the first api_retry 401 interrupts the turn, which fails as auth", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.prompt("retry401");
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "failed", reason: "auth", message: "401 invalid token" });
    const interrupts = stdin(o.dump).filter((m) => m.type === "control_request" && m.request.subtype === "interrupt");
    assert.equal(interrupts.length, 1, "interrupted once");
    assert.match(interrupts[0].request_id, /^interrupt-/);
    await session.dispose();
  });

  test("abort interrupts the turn; its end still comes, as aborted", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.abort(); // nothing running: nothing sent
    await session.prompt("hold:2");
    await until((e) => deltas(e).length >= 2);
    await session.abort();
    await session.abort(); // once
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "aborted" });
    assert.equal(stdin(o.dump).filter((m) => m.type === "control_request").length, 1);
    assert.deepEqual(deltas(events), ["d0 ", "d1 "]);
    await session.dispose();
  });

  test("steer adds input to the running turn; with nothing running it is refused", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    assert.equal(await session.steer("early"), false);
    await session.prompt("hold:1");
    await until((e) => deltas(e).length >= 1);
    assert.equal(await session.steer("more"), true);
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.ok(deltas(events).includes("steer:more"));
    assert.equal(events.filter((e) => e.type === "turnStarted").length, 0);
    await session.dispose();
  });

  test("a turn that starts without a prompt of ours is told as turnStarted", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    await session.prompt("again");
    await until(ended(2));
    const kinds = events.filter((e) => e.type !== "live").map((e) => e.type);
    assert.deepEqual(kinds, ["turnEnded", "turnStarted", "turnEnded"]);
    assert.equal(session.busy(), false);
    await session.dispose();
  });

  test("the process exiting during a turn fails it as exited, with its last stderr, then closes the session", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    await session.prompt("exit");
    await until((e) => e.some((x) => x.type === "closed"));
    const told = events.filter((e) => e.type !== "live");
    assert.deepEqual(told, [
      { type: "turnEnded", outcome: { kind: "failed", reason: "exited", message: "claude exited (3) during the turn: noise\nerror: An unknown error occurred (Unexpected)" } },
      { type: "closed", why: "claude exited (3): noise\nerror: An unknown error occurred (Unexpected)" },
    ]);
    await assert.rejects(session.prompt("again"), /closed/);
    // Read to the end, its runner is gone.
    await eventually(async () => !(await existingRunners(data)).some((r) => r.args.includes(session.id())));
  });

  test("background_tools sends background_tasks; the call it waited on returns and the turn goes on", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.backgroundTools(); // nothing running: nothing sent
    await session.prompt("tool");
    // The call starts again with its input once that is complete.
    await until((e) => e.some((x) => x.type === "live" && x.event.kind === "start" && x.event.input === '{"command":"sleep 60"}'));
    await session.backgroundTools();
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    const requests = stdin(o.dump).filter((m) => m.type === "control_request");
    assert.equal(requests.length, 1);
    assert.equal(requests[0].request.subtype, "background_tasks");
    assert.match(requests[0].request_id, /^background-/);
    const live = events.flatMap((e) => (e.type === "live" ? [e.event] : []));
    assert.ok(live.some((e) => e.kind === "delta" && e.id === "call_1" && e.field === "output" && e.text === "moved to background"));
    assert.ok(live.some((e) => e.kind === "end" && e.id === "call_1"));
    await session.dispose();
  });

  test("a machine profile runs on the machine's token, and is not prompted once it is about to run out", async () => {
    let expiresAt = Date.now() + 3600_000;
    const d = driver(async () => ({ token: "machine-token", expiresAt }));
    const o = options({ machine: true });
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.prompt("say:hi");
    await until(ended(1));
    const env = JSON.parse(readFileSync(o.dump, "utf8").trim()).env;
    assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, "machine-token");
    if (process.platform === "darwin") assert.doesNotMatch(env.PATH.split(":")[0], /stillfail-no-keychain/);
    await session.dispose();
    expiresAt = Date.now() + 60_000;
    const soon = await d.open(options({ machine: true }), () => {});
    await assert.rejects(soon.prompt("say:hi"), /token runs out/);
    await soon.dispose();
  });

  for (const crashed of [false, true]) {
    test(`a next driver takes the session up ${crashed ? "after a crash (no snapshot)" : "from its snapshot"}: the turn ends once, no live event twice`, async () => {
      const first = driver();
      const o = options();
      const a = listen();
      const session = await first.open(o, a.push);
      const gate = gates(o.dump, "g");
      await session.prompt("gate:12:4:g");
      await a.until((e) => deltas(e).length >= 4);
      let snapshot: unknown = null;
      if (!crashed) snapshot = JSON.parse(JSON.stringify(session.snapshot()));
      // Stops: the process goes on under its runner, saying the rest of its reply with nobody reading.
      first.detach();
      await gate.open("a");
      await eventually(gate.said);
      const next = driver();
      const b = listen();
      const taken: AgentSession = await next.adopt(o, snapshot, b.push);
      assert.equal(taken.id(), session.id());
      assert.equal(taken.busy(), true);
      await gate.open("b");
      await b.until(ended(1));
      const all = [...a.events, ...b.events];
      assert.equal(ends(all).length, 1, "the turn's end, once");
      assert.deepEqual(outcome(b.events), { kind: "completed" });
      assert.deepEqual(deltas(all), Array.from({ length: 12 }, (_, i) => `d${i} `), "every delta once, in order");
      assert.equal(all.filter((e) => e.type === "live" && e.event.kind === "start").length, 1);
      assert.equal(all.filter((e) => e.type === "live" && e.event.kind === "end").length, 1, "the step started before ends after");
      // After a crash the new station is told a turn is running that it did not start.
      assert.equal(b.events.filter((e) => e.type === "turnStarted").length, crashed ? 1 : 0);
      // It goes on as before.
      await taken.prompt("say:after");
      await b.until(ended(2));
      assert.deepEqual(outcome(b.events, 1), { kind: "completed" });
      await taken.dispose();
      await b.until((e) => e.some((x) => x.type === "closed"));
      assert.ok(!a.events.some((e) => e.type === "closed"), "the first driver hears nothing after letting go");
    });
  }
});
