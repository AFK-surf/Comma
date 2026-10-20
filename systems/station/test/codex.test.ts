// The Codex driver (src/agents/codex.ts) against a fake app-server (test/fake/codex: JSON-RPC as codex speaks it) under
// the real runner: turns, failures by their code, abort, steer, a turn of its own, the app-server exiting, one
// app-server per profile and its restart once a profile edit leaves it idle, what it is started with, and threads taken
// up by a next driver (with a snapshot, and after a crash) with the turn's end told once and no live event twice.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { CodexDriver, classifyCodexError, type CodexDriverOptions } from "../src/agents/codex.ts";
import { existingRunners } from "../src/agents/runner.ts";
import type { OpenOptions, Profile, RuntimeEvent } from "../src/agents/runtime.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;
// Inherited, and not to reach the agent.
process.env.OPENAI_API_KEY = "leaked";
process.env.CODEX_HOME = "/nowhere";
// Short: the runners' sockets live under it (104 bytes at most on macOS).
const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "cx-") : "/tmp/cx-");
const skills = join(data, "skills");
mkdirSync(join(skills, "mine"), { recursive: true });
writeFileSync(join(skills, "mine", "SKILL.md"), "");
const bundle = join(data, "cert.pem");
writeFileSync(bundle, "");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `done` holds: what real processes do has no event here. No deadline (it comes, however
/// slow the machine, or the test hangs).
async function eventually(done: () => boolean | Promise<boolean>) {
  while (!(await done())) await sleep(20);
}
/// The fifos a `gate:<n>:<k>:<name>` turn waits at (test/fake/codex.mjs): `open(part)` lets it go on.
function gates(dump: string, name: string) {
  const at = `${dump}.${name}`;
  if (process.platform !== "win32") for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${at}.${part}`]);
  return { open: (part: "a" | "b") => writeFile(`${at}.${part}`, "go"), said: () => existsSync(`${at}.said`) };
}
const drivers: CodexDriver[] = [];
after(async () => {
  await Promise.all(drivers.map((d) => d.shutdown()));
  rmSync(data, { recursive: true, force: true });
});

function driver(more: Partial<CodexDriverOptions> = {}) {
  const d = new CodexDriver({ data, hostSkills: skills, caBundle: bundle, ...more });
  drivers.push(d);
  return d;
}

let n = 0;
/// A profile of its own (so an app-server of its own), its starts and stdin dumped.
function profile(extra: Record<string, unknown> = {}): Profile & { dump: string } {
  const i = ++n;
  const home = join(data, `h${i}`);
  const dump = join(data, `dump${i}`);
  return { id: `cx${i}`, runtime: "codex", home, credential: "api_key", source: "opencode-go", key: "k2", env: { FAKE_DUMP: dump }, dump, ...extra };
}

function options(p: Profile, extra: Partial<OpenOptions> = {}): OpenOptions {
  return { key: `chat:${p.id}:${++n}`, profile: p, cwd: data, instructions: "be brief", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r", ...extra };
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
const starts = (dump: string) => readFileSync(dump, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const stdin = (dump: string) => readFileSync(`${dump}.stdin`, "utf8").trim().split("\n").map((l) => JSON.parse(l));

// Each test has its own driver, profile and runners: they run side by side.
describe("the Codex driver", { concurrency: true }, () => {
  test("a turn completes, on an app-server started with the flags and environment of codex.rs", async () => {
    const d = driver();
    const p = profile();
    const { events, push, until } = listen();
    const session = await d.open(options(p, { model: "gpt-x", effort: "high" }), push);
    assert.match(session.id(), /^th-/);
    await session.prompt("cmd");
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.ok(!events.some((e) => e.type === "turnStarted"));
    const live = events.flatMap((e) => (e.type === "live" ? [e.event] : []));
    const steps = live.filter((e) => e.kind !== "phase");
    const command = (steps[0] as { id: string }).id;
    assert.deepEqual(steps.slice(0, 3), [
      { kind: "start", id: command, step: "tool", tool: "shell", input: "ls" },
      { kind: "delta", id: command, field: "output", text: "a\n" },
      { kind: "end", id: command },
    ]);
    assert.deepEqual(steps.slice(3).map((e) => e.kind), ["start", "delta", "end"]);
    assert.deepEqual(live.filter((e) => e.kind === "phase").map((e) => (e as { phase: string }).phase), ["requesting", "working", "requesting", "responding"]);

    const [started] = starts(p.dump);
    assert.deepEqual(started.argv, [
      "app-server",
      "-c", "features.apps=false",
      "-c", "features.plugins=false",
      "-c", "features.recommended_plugins=false",
      "-c", 'model_provider="opencode-go"',
      "-c", 'model_providers.opencode-go.base_url="https://opencode.ai/zen/go/v1"',
      "-c", 'model_providers.opencode-go.env_http_headers={"x-opencode-session"="OPENCODE_SESSION"}',
      "-c", 'model_providers.opencode-go.env_key="OPENCODE_GO_KEY"',
      "-c", 'model_providers.opencode-go.name="OpenCode Go"',
      "-c", 'model_providers.opencode-go.wire_api="responses"',
      "--listen", "stdio://",
    ]);
    assert.equal(started.env.CODEX_HOME, p.home);
    assert.equal(started.env.OPENAI_API_KEY, undefined);
    assert.equal(started.env.SSL_CERT_FILE, bundle);
    assert.equal(started.env.OPENCODE_GO_KEY, "k2");
    assert.equal(started.env.OPENCODE_SESSION, `ember-${p.id}`, "a codex route is its profile");

    const sent = stdin(p.dump);
    assert.deepEqual(sent[0], { id: 1, method: "initialize", params: { clientInfo: { name: "stillfail", version: "0" }, capabilities: { experimentalApi: true } } });
    assert.deepEqual(sent[1], { method: "initialized", params: {} });
    assert.deepEqual(sent[2], {
      id: 2,
      method: "thread/start",
      params: {
        cwd: data,
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        developerInstructions: "be brief",
        config: {
          "mcp_servers.stillfail.url": "http://127.0.0.1:4750/mcp",
          "mcp_servers.stillfail.http_headers": { Authorization: "Bearer tok" },
          model_reasoning_effort: "high",
          "skills.config": [{ path: join(skills, "mine", "SKILL.md"), enabled: false }],
        },
        model: "gpt-x",
      },
    });
    // Not a subscription: no service tier.
    assert.deepEqual(sent[3], { id: 3, method: "turn/start", params: { threadId: session.id(), input: [{ type: "text", text: "cmd" }] } });
    await session.dispose();
    assert.equal(stdin(p.dump).at(-1).method, "thread/unsubscribe");
  });

  test("a failed turn is told apart by its codexErrorInfo", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(profile()), push);
    for (const [i, prompt] of ["fail:auth", "fail:rate", "fail:model"].entries()) {
      await session.prompt(prompt);
      await until(ended(i + 1));
    }
    assert.deepEqual(outcome(events, 0), { kind: "failed", reason: "auth", message: "unauthorized: token expired" });
    assert.deepEqual(outcome(events, 1), { kind: "failed", reason: "rate_limit", message: "usage limit reached" });
    assert.deepEqual(outcome(events, 2), { kind: "failed", reason: "model", message: "model not supported" });
    assert.equal(classifyCodexError(null), "model");
    assert.equal(classifyCodexError({ serverOverloaded: null }), "rate_limit");
  });

  test("abort interrupts the running turn by its id; steer adds to it, and is refused with nothing running", async () => {
    const d = driver();
    const p = profile();
    const { events, push, until } = listen();
    const session = await d.open(options(p), push);
    assert.equal(await session.steer("early"), false);
    await session.prompt("hold:1");
    await until((e) => deltas(e).length >= 1);
    assert.equal(await session.steer("more"), true);
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.ok(deltas(events).includes("steer:more"));
    const steer = stdin(p.dump).find((m) => m.method === "turn/steer");
    assert.deepEqual(steer.params, { threadId: session.id(), input: [{ type: "text", text: "more" }], expectedTurnId: steer.params.expectedTurnId });
    assert.match(steer.params.expectedTurnId, /^tu-/);

    assert.deepEqual(deltas(events), ["d0 ", "steer:more"]);
    await session.prompt("hold:3");
    await until((e) => deltas(e).length >= 5);
    await session.abort();
    await until(ended(2));
    assert.deepEqual(outcome(events, 1), { kind: "aborted" });
    assert.deepEqual(deltas(events).slice(2), ["d0 ", "d1 ", "d2 "]);
    const interrupt = stdin(p.dump).find((m) => m.method === "turn/interrupt");
    assert.equal(interrupt.params.threadId, session.id());
    assert.match(interrupt.params.turnId, /^tu-/);
    await session.backgroundTools(); // nothing for codex
  });

  test("a turn that starts without a prompt of ours is told as turnStarted; codex's own questions are refused", async () => {
    const d = driver();
    const p = profile();
    const { events, push, until } = listen();
    const session = await d.open(options(p), push);
    await session.prompt("again");
    await until(ended(2));
    assert.deepEqual(events.filter((e) => e.type !== "live").map((e) => e.type), ["turnEnded", "turnStarted", "turnEnded"]);
    await session.prompt("ask");
    await until(ended(3));
    assert.ok(stdin(p.dump).some((m) => m.id === "srv-1" && m.error?.code === -32601));
  });

  test("the app-server exiting fails the thread's turn as exited and closes every thread on it", async () => {
    const d = driver();
    const p = profile();
    const a = listen();
    const b = listen();
    const one = await d.open(options(p), a.push);
    const two = await d.open(options(p), b.push);
    assert.equal(starts(p.dump).length, 1, "one app-server for the profile's threads");
    await one.prompt("exit");
    await a.until((e) => e.some((x) => x.type === "closed"));
    await b.until((e) => e.some((x) => x.type === "closed"));
    assert.deepEqual(a.events.filter((e) => e.type !== "live"), [
      { type: "turnEnded", outcome: { kind: "failed", reason: "exited", message: "codex app-server exited (4)" } },
      { type: "closed", why: "codex app-server exited (4)" },
    ]);
    assert.deepEqual(b.events, [{ type: "closed", why: "codex app-server exited (4)" }]);
    await assert.rejects(two.prompt("x"), /closed/);
    // The next session starts it again.
    const c = listen();
    const three = await d.open(options(p), c.push);
    await three.prompt("say:back");
    await c.until(ended(1));
    assert.equal(starts(p.dump).length, 2);
  });

  test("a profile edit restarts its app-server only once no thread uses it", async () => {
    const d = driver();
    const p = profile();
    const one = await d.open(options(p), () => {});
    const edited = { ...p, env: { ...(p.env as object), EXTRA: "1" } };
    const two = await d.open(options(edited), () => {});
    assert.equal(starts(p.dump).length, 1, "in use: it keeps serving");
    await one.dispose();
    await two.dispose();
    const { push, until } = listen();
    const three = await d.open(options(edited), push);
    assert.equal(starts(p.dump).length, 2);
    assert.equal(starts(p.dump)[1].env.EXTRA, "1");
    await three.prompt("say:x");
    await until(ended(1));
  });

  test("a subscription's turns say their service tier; models and rate limits come from the app-server", async () => {
    let fast: boolean | undefined = true;
    const d = driver({ fast: () => fast });
    const p = profile({ credential: "subscription", source: "codex" });
    const { push, until } = listen();
    const session = await d.open(options(p), push);
    await session.prompt("say:a");
    await until(ended(1));
    fast = undefined;
    await session.prompt("say:b");
    await until(ended(2));
    const tiers = stdin(p.dump).filter((m) => m.method === "turn/start").map((m) => m.params.serviceTier);
    assert.deepEqual(tiers, ["fast", null], "an explicit null clears a tier chosen before");
    const started = starts(p.dump)[0];
    assert.deepEqual(started.argv, ["app-server", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "features.recommended_plugins=false", "--listen", "stdio://"]);
    const catalog = await d.models(p);
    assert.deepEqual(catalog.models, ["gpt-a", "legacy"]);
    assert.deepEqual(catalog.efforts.get("gpt-a"), ["low", "high"]);
    assert.deepEqual(await d.rateLimits(p), { rateLimits: { primary: { usedPercent: 5 } } });
  });

  for (const crashed of [false, true]) {
    test(`a next driver takes the threads up ${crashed ? "after a crash (no snapshot)" : "from their snapshots"}: each turn ends once, no live event twice`, async () => {
      const first = driver();
      const p = profile();
      const a = listen();
      const a2 = listen();
      const one = await first.open(options(p), a.push);
      const two = await first.open(options(p), a2.push);
      const [gateOne, gateTwo] = [gates(p.dump, "one"), gates(p.dump, "two")];
      await one.prompt("gate:12:4:one");
      await two.prompt("gate:14:4:two");
      await a.until((e) => deltas(e).length >= 4);
      await a2.until((e) => deltas(e).length >= 4);
      // A request in flight as it lets go: its reply goes to the next driver, which drops it.
      const steering = one.steer("late");
      let snapshots: unknown[] = [null, null];
      if (!crashed) snapshots = JSON.parse(JSON.stringify([one.snapshot(), two.snapshot()]));
      first.detach();
      assert.equal(await steering, false, "its reply is the next station's");
      // The app-server has the steer; the first turn says the rest of its reply with nobody reading.
      await eventually(() => stdin(p.dump).some((m) => m.method === "turn/steer"));
      await gateOne.open("a");
      await eventually(gateOne.said);
      const next = driver();
      const b = listen();
      const b2 = listen();
      const takenOne = await next.adopt(options(p, { resume: one.id() }), snapshots[0], b.push);
      // The second is taken up later: what came for it meanwhile (the rest of its reply) waits for it.
      await gateTwo.open("a");
      await eventually(gateTwo.said);
      const takenTwo = await next.adopt(options(p, { resume: two.id() }), snapshots[1], b2.push);
      assert.equal(takenOne.id(), one.id());
      await Promise.all([gateOne.open("b"), gateTwo.open("b")]);
      await b.until(ended(1));
      await b2.until(ended(1));
      for (const [before, now, count] of [[a, b, 12], [a2, b2, 14]] as const) {
        const all = [...before.events, ...now.events];
        assert.equal(ends(all).length, 1, "the turn's end, once");
        assert.deepEqual(outcome(now.events), { kind: "completed" });
        const said = deltas(all).filter((t) => !t.startsWith("steer:"));
        assert.deepEqual(said, Array.from({ length: count }, (_, i) => `d${i} `), "every delta once, in order");
        assert.equal(all.filter((e) => e.type === "live" && e.event.kind === "start").length, 1);
        assert.equal(all.filter((e) => e.type === "live" && e.event.kind === "end").length, 1);
        assert.equal(now.events.filter((e) => e.type === "turnStarted").length, crashed ? 1 : 0);
      }
      assert.ok(deltas([...a.events, ...b.events]).includes("steer:late"), "the steer itself reached the turn");
      assert.equal(starts(p.dump).length, 1, "the same app-server");
      // It goes on: new requests on the app-server taken up.
      await takenOne.prompt("say:after");
      await b.until(ended(2));
      assert.deepEqual(outcome(b.events, 1), { kind: "completed" });
      assert.ok(!a.events.some((e) => e.type === "closed"));
    });
  }

  test("shutdown ends the app-servers and their runners", async () => {
    const d = new CodexDriver({ data, hostSkills: skills, caBundle: bundle });
    const p = profile();
    await d.open(options(p), () => {});
    const pid = starts(p.dump)[0].pid;
    await d.shutdown();
    const alive = () => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    await eventually(async () => !alive() && !(await existingRunners(data)).some((r) => r.pid === pid));
    assert.throws(() => process.kill(pid, 0));
    assert.ok(!(await existingRunners(data)).some((r) => r.pid === pid));
  });
});
