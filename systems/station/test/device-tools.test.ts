// The device tools (src/device/tools.ts, contract v1 §8): what each access level lets through, and each op family —
// exec, files, processes, the runtimes here, the station's chats — on a temporary home.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chmodSync, existsSync, readFileSync, mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { type Access, DeviceTools, OPS, READ_OPS, type Sessions, accessOf, permitted } from "../src/device/tools.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { WINDOWS } from "../src/platform/index.ts";

const run = (tools: DeviceTools, op: string, args: Record<string, unknown> = {}, access: Access = "full") =>
  Effect.runPromise(Effect.result(tools.run(op, args, { user_email: "a@x" }, access))).then((r) =>
    r._tag === "Success" ? { ok: true as const, result: r.success as any } : { ok: false as const, code: r.failure.code, message: r.failure.message },
  );

function tools(sessions?: Sessions) {
  const home = mkdtempSync(join(tmpdir(), "tools-"));
  const t = new DeviceTools({ home, env: { PATH: process.env.PATH, HOME: home }, sessions });
  return { home, t };
}

test("agent conversations use separate default directories while explicit shared paths remain available", async (tst) => {
  const { t, home } = tools();
  tst.after(() => t.close());
  const invoke = (op: string, args: Record<string, unknown>, agent: string, conversation: string, workspace = "ws") =>
    Effect.runPromise(t.run(op, args, { workspace, agent, conversation }, "full")) as Promise<any>;
  const [a, b] = await Promise.all([
    invoke("exec", { command: "printf alpha > result.txt; pwd" }, "worker", "task-a"),
    invoke("exec", { command: "printf beta > result.txt; pwd" }, "worker", "task-b"),
  ]);
  const c = await invoke("exec", { command: "pwd" }, "other-worker", "task-a");
  const d = await invoke("exec", { command: "pwd" }, "worker", "task-a", "other-ws");
  assert.equal(new Set([a.cwd, b.cwd, c.cwd, d.cwd]).size, 4);
  const own = await invoke("fs.read", { path: "result.txt" }, "worker", "task-a");
  assert.equal(Buffer.from(own.content_base64, "base64").toString(), "alpha");
  await invoke("fs.write", { path: "result.txt", content_base64: Buffer.from("updated").toString("base64") }, "worker", "task-b");
  const unchanged = await invoke("exec", { command: "cat result.txt" }, "worker", "task-a");
  assert.equal(unchanged.stdout, "alpha");
  const shared = await invoke("exec", { command: "pwd", cwd: home }, "worker", "task-a");
  assert.equal(realpathSync(shared.cwd), realpathSync(home));
  const process = await invoke("process.start", { command: "cat" }, "worker", "task-b");
  assert.equal(process.cwd, b.cwd);
  const listed = await invoke("process.list", {}, "worker", "task-a");
  assert.deepEqual(listed.processes[0].context, { workspace: "ws", agent: "worker", conversation: "task-b" });
  await invoke("process.stop", { process_id: process.process_id }, "worker", "task-b");
});

test("presence tools retain agent files across Workspace rename and keep original process context", async (tst) => {
  const { presenceTools } = await import("../src/mesh/tools.ts");
  const { t } = tools();
  tst.after(() => t.close());
  const cloud = { state: { workspace: "old-ws" }, removed: () => false } as any;
  const call = presenceTools({ cloud, tools: t, access: () => "full", enabled: () => true });
  const ask = (op: string, args: Record<string, unknown>, workspace: string) =>
    call({ op, args, context: { workspace, agent: "worker", conversation: "task" } }) as Promise<any>;
  const first = await ask("exec", { command: "printf retained > a.txt" }, "old-ws");
  assert.equal(first.ok, true);
  cloud.state = { workspace: "new-ws", workspace_was: ["old-ws"] };
  const next = await ask("exec", { command: "cat a.txt" }, "new-ws");
  assert.equal(next.result.cwd, first.result.cwd);
  assert.equal(next.result.stdout, "retained");
  const old = await ask("fs.read", { path: "a.txt" }, "old-ws");
  assert.equal(Buffer.from(old.result.content_base64, "base64").toString(), "retained");
  const process = await ask("process.start", { command: "cat" }, "new-ws");
  const list = await ask("process.list", {}, "new-ws");
  assert.equal(list.result.processes[0].context.workspace, "new-ws");
  assert.equal(process.result.cwd, first.result.cwd);
  const wrong = await ask("exec", { command: "echo wrong" }, "another-ws");
  assert.equal(wrong.ok, false);
  assert.equal(wrong.error.code, "forbidden");
});

test("the VMM image initializes full tools once and preserves every existing configuration", async (tst) => {
  const { presenceTools } = await import("../src/mesh/tools.ts");
  const { t, home } = tools();
  tst.after(() => t.close());
  const data = join(home, "data");
  const initialize = fileURLToPath(new URL("../../runtime-images/station/initialize-access.mjs", import.meta.url));
  const old = { COMMA_STATION_CONFIG: process.env.COMMA_STATION_CONFIG, EMBER_CONFIG: process.env.EMBER_CONFIG };
  tst.after(() => {
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  process.env.COMMA_STATION_CONFIG = "";
  process.env.EMBER_CONFIG = "";
  const boot = () => execFileSync(process.execPath, [initialize, data], { env: process.env });
  boot();
  const config = new ConfigFile(data);
  assert.equal(accessOf(config.raw()), "full");
  const cloud = { state: { workspace: "ws" }, removed: () => false } as any;
  const call = presenceTools({ cloud, tools: t, access: () => accessOf(config.raw()), enabled: () => true });
  const request = { op: "exec", args: { command: "printf usable" }, context: { workspace: "ws", agent: "worker", conversation: "task" } };
  const first = await call(request) as any;
  assert.equal(first.result.stdout, "usable");
  for (const access of ["off", "read", "full"] as const) {
    config.update((raw) => { raw.tools.access = access; raw.keep = "member configuration"; });
    const bytes = readFileSync(config.path, "utf8");
    boot();
    assert.equal(readFileSync(config.path, "utf8"), bytes);
    assert.equal((await call(request) as any).ok, access === "full");
  }
  for (const bytes of ["{}", "broken config"]) {
    writeFileSync(config.path, bytes);
    boot();
    assert.equal(readFileSync(config.path, "utf8"), bytes);
  }
  // The initializer and ConfigFile honor the same explicit path precedence.
  process.env.EMBER_CONFIG = join(home, "ember.json");
  process.env.COMMA_STATION_CONFIG = join(home, "preferred.json");
  boot();
  const custom = new ConfigFile(data);
  assert.equal(custom.path, process.env.COMMA_STATION_CONFIG);
  assert.equal(accessOf(custom.raw()), "full");
  assert.equal(existsSync(process.env.EMBER_CONFIG), false);
});

test("access: off refuses everything, read only the reads, full everything; unset is off", async () => {
  assert.equal(accessOf({}), "off");
  assert.equal(accessOf({ tools: { access: "full" } }), "full");
  assert.equal(accessOf({ tools: { access: "bogus" } }), "off");
  for (const op of OPS) {
    assert.equal(permitted("off", op), false);
    assert.equal(permitted("read", op), READ_OPS.includes(op), op);
    assert.equal(permitted("full", op), true);
  }
  const { t, home } = tools();
  writeFileSync(join(home, "a.txt"), "hi");
  assert.equal((await run(t, "fs.read", { path: "a.txt" }, "read")).ok, true);
  const refused = await run(t, "exec", { command: "echo no" }, "read");
  assert.equal(refused.ok, false);
  assert.equal(!refused.ok && refused.code, "forbidden");
  const off = await run(t, "fs.read", { path: "a.txt" }, "off");
  assert.equal(!off.ok && off.code, "forbidden");
  const unknown = await run(t, "rm.rf", {}, "full");
  assert.equal(!unknown.ok && unknown.code, "unknown_op");
  // config.json takes only the levels there are.
  assert.doesNotThrow(() => checkConfig({ tools: { access: "full" } }, home));
  assert.throws(() => checkConfig({ tools: { access: "all" } }, home), /tools.access/);
});

test("exec: exit code and output, each capped at 1 MiB, a timeout ending it", async () => {
  const { t, home } = tools();
  // Git Bash's pwd says /c/…: -W says it as Windows does (with /).
  const echo = await run(t, "exec", { command: `echo out; echo err >&2; pwd${WINDOWS ? " -W" : ""}; exit 3` });
  assert.ok(echo.ok);
  assert.equal(echo.result.exit_code, 3);
  // It runs in the home directory.
  assert.equal(echo.result.stdout, `out\n${WINDOWS ? realpathSync(home).replaceAll("\\", "/") : realpathSync(home)}\n`);
  assert.equal(echo.result.stderr, "err\n");
  assert.equal(echo.result.truncated, false);
  const env = await run(t, "exec", { command: "echo $GREETING", env: { GREETING: "hello" } });
  assert.ok(env.ok && env.result.stdout === "hello\n");
  const big = await run(t, "exec", { command: "head -c 2000000 /dev/zero" });
  assert.ok(big.ok && big.result.truncated === true && big.result.stdout.length === 1024 * 1024);
  // One that never ends by itself: timed out, however slow the machine.
  const slow = await run(t, "exec", { command: "tail -f /dev/null", timeout_ms: 200 });
  assert.ok(slow.ok && slow.result.timed_out === true);
  const missing = await run(t, "exec", {});
  assert.equal(!missing.ok && missing.code, "invalid_request");
});

test("files: write, append, read in parts, list, stat; a missing one is not_found", async () => {
  const { t, home } = tools();
  const b64 = (s: string) => Buffer.from(s).toString("base64");
  assert.ok((await run(t, "fs.write", { path: "d/x.txt", content_base64: b64("hello ") })).ok);
  assert.ok((await run(t, "fs.write", { path: join(home, "d/x.txt"), content_base64: b64("world"), append: true })).ok);
  const all = await run(t, "fs.read", { path: "d/x.txt" });
  assert.ok(all.ok);
  assert.equal(Buffer.from(all.result.content_base64, "base64").toString(), "hello world");
  assert.equal(all.result.size, 11);
  assert.equal(all.result.eof, true);
  const part = await run(t, "fs.read", { path: "d/x.txt", offset: 6, length: 3 });
  assert.ok(part.ok && Buffer.from(part.result.content_base64, "base64").toString() === "wor" && part.result.eof === false);
  mkdirSync(join(home, "d", "sub"));
  const list = await run(t, "fs.list", { path: "d" });
  assert.ok(list.ok);
  assert.deepEqual(list.result.entries.map((e: any) => [e.name, e.type]), [["sub", "dir"], ["x.txt", "file"]]);
  const stat = await run(t, "fs.stat", { path: "d/x.txt" });
  assert.ok(stat.ok && stat.result.type === "file" && stat.result.size === 11 && typeof stat.result.mtime_ms === "number");
  const gone = await run(t, "fs.stat", { path: "nope" });
  assert.equal(!gone.ok && gone.code, "not_found");
});

test("processes: started, written to, tailed from where the last tail ended, listed, stopped", async () => {
  const { t } = tools();
  const started = await run(t, "process.start", { command: "cat" });
  assert.ok(started.ok);
  const id = started.result.process_id;
  assert.ok((await run(t, "process.write", { process_id: id, data_base64: Buffer.from("one\n").toString("base64") })).ok);
  /// Tails it (from `since`) every 20 ms until `done` says what came is what was waited for (a real process: no
  /// deadline).
  const tailUntil = async (since: number | undefined, done: (got: any) => boolean) => {
    for (;;) {
      const got = await run(t, "process.tail", since === undefined ? { process_id: id } : { process_id: id, since });
      if (done(got)) return got;
      await new Promise((r) => setTimeout(r, 20));
    }
  };
  const tail = await tailUntil(undefined, (got) => got.ok && got.result.next > 0);
  assert.equal(Buffer.from(tail.result.data_base64, "base64").toString(), "one\n");
  assert.equal(tail.result.exited, false);
  const next = tail.result.next;
  await run(t, "process.write", { process_id: id, data_base64: Buffer.from("two\n").toString("base64") });
  const more = await tailUntil(next, (got) => got.ok && got.result.next > next);
  assert.equal(Buffer.from(more.result.data_base64, "base64").toString(), "two\n");
  const listed = await run(t, "process.list");
  assert.ok(listed.ok && listed.result.processes.some((p: any) => p.process_id === id && p.command === "cat"));
  assert.ok((await run(t, "process.stop", { process_id: id })).ok);
  const ended = await tailUntil(more.result.next, (got) => got.result.exited);
  assert.ok("exit_code" in ended.result);
  const unknown = await run(t, "process.tail", { process_id: "p999" });
  assert.equal(!unknown.ok && unknown.code, "not_found");
  t.close();
});

test("runtime.probe: the runtimes on PATH, their versions, whether this machine is signed in to them", async () => {
  const home = mkdtempSync(join(tmpdir(), "probe-"));
  const bin = join(home, "bin");
  mkdirSync(bin);
  // On Windows as npm puts them there: .cmd shims.
  const [claude, codex] = WINDOWS ? ["claude.cmd", "codex.cmd"] : ["claude", "codex"];
  writeFileSync(join(bin, claude), WINDOWS ? "@echo 2.1.284 (Claude Code)\r\n" : "#!/bin/sh\necho '2.1.284 (Claude Code)'\n");
  writeFileSync(join(bin, codex), WINDOWS ? "@echo codex-cli 0.46.0\r\n" : "#!/bin/sh\necho 'codex-cli 0.46.0'\n");
  chmodSync(join(bin, claude), 0o755);
  chmodSync(join(bin, codex), 0o755);
  mkdirSync(join(home, ".codex"));
  writeFileSync(join(home, ".codex", "auth.json"), "{}");
  const t = new DeviceTools({ home, env: { PATH: bin, HOME: home } });
  const probe = await run(t, "runtime.probe", {}, "read");
  assert.ok(probe.ok);
  assert.deepEqual(probe.result.runtimes, [
    { kind: "claude", path: join(bin, claude), version: "2.1.284", signed_in: false },
    { kind: "codex", path: join(bin, codex), version: "0.46.0", signed_in: true },
  ]);
});

test("sessions: started and said to as the requester under full access, asked about under read", async () => {
  const calls: unknown[] = [];
  const sessions: Sessions = {
    start: async (a) => (calls.push(["start", a]), { session: "ember:1", thread: "7" }),
    say: async (a) => void calls.push(["say", a]),
    status: (thread) => (thread === "7" ? { state: "all_done", summary: "done" } : null),
  };
  const { t } = tools(sessions);
  const started = await run(t, "session.start", { prompt: "fix it", requester_email: "b@x" });
  assert.deepEqual(started, { ok: true, result: { session: "ember:1", thread: "7" } });
  assert.ok((await run(t, "session.say", { thread: "7", text: "more", requester_email: "b@x" })).ok);
  assert.deepEqual(calls, [["start", { prompt: "fix it", title: null, runtime: null, requester: "b@x" }], ["say", { thread: "7", text: "more", requester: "b@x" }]]);
  assert.deepEqual(await run(t, "session.status", { thread: "7" }), { ok: true, result: { state: "all_done", summary: "done" } });
  const unknown = await run(t, "session.status", { thread: "8" });
  assert.equal(!unknown.ok && unknown.code, "not_found");
  // Status is a read; starting and saying are not.
  assert.ok((await run(t, "session.status", { thread: "7" }, "read")).ok);
  const read = await run(t, "session.say", { thread: "7", text: "x", requester_email: "b@x" }, "read");
  assert.equal(!read.ok && read.code, "forbidden");
  const noPrompt = await run(t, "session.start", { requester_email: "b@x" });
  assert.equal(!noPrompt.ok && noPrompt.code, "invalid_request");
});

test("the station's data and the machine's logins are refused at every level, also through a link or as a cwd", async () => {
  const home = mkdtempSync(join(tmpdir(), "guard-"));
  const data = join(home, ".comma-station");
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "secret.key"), "k");
  mkdirSync(join(home, ".codex"));
  writeFileSync(join(home, ".codex", "auth.json"), "{}");
  writeFileSync(join(home, ".codex", "config.toml"), "");
  symlinkSync(data, join(home, "innocent"));
  const t = new DeviceTools({ home, env: { PATH: process.env.PATH, HOME: home }, protect: () => [data, join(home, ".codex", "auth.json")] });
  const refused = async (op: string, args: Record<string, unknown>, access: Access) => {
    const r = await run(t, op, args, access);
    assert.equal(!r.ok && r.code, "forbidden", `${op} ${JSON.stringify(args)} under ${access}`);
  };
  for (const access of ["read", "full"] as Access[]) {
    await refused("fs.read", { path: ".comma-station/mesh/secret.key" }, access);
    await refused("fs.read", { path: join(data, "mesh", "secret.key") }, access);
    await refused("fs.read", { path: "innocent/mesh/secret.key" }, access);
    await refused("fs.list", { path: ".comma-station" }, access);
    await refused("fs.stat", { path: "innocent" }, access);
    await refused("fs.read", { path: ".codex/auth.json" }, access);
  }
  // Spelled in another case, as a case-insensitive file system (macOS's) takes it.
  if (existsSync(join(home, ".COMMA-STATION"))) {
    await refused("fs.read", { path: ".COMMA-STATION/MESH/secret.key" }, "read");
    await refused("fs.read", { path: join(home, ".Comma-Station", "mesh", "SECRET.KEY") }, "full");
    await refused("fs.write", { path: ".COMMA-STATION/new/thing", content_base64: "" }, "full");
    await refused("fs.read", { path: ".CODEX/AUTH.JSON" }, "read");
  }
  await refused("fs.write", { path: "innocent/mesh/secret.key", content_base64: "" }, "full");
  await refused("fs.write", { path: ".comma-station/new-file", content_base64: "" }, "full");
  await refused("exec", { command: "pwd", cwd: ".comma-station" }, "full");
  await refused("process.start", { command: "cat", cwd: "innocent" }, "full");
  // What is beside them is not.
  assert.ok((await run(t, "fs.read", { path: ".codex/config.toml" }, "read")).ok);
  assert.ok((await run(t, "fs.list", { path: "." }, "read")).ok);
});

test("a device tools request line may be long; the admin API's heads stay short", async () => {
  const { Reader } = await import("../src/mesh/serve.ts");
  const { MAX_TOOLS_LINE } = await import("../src/mesh/tools.ts");
  // A stream giving `bytes` in 64 KiB pieces.
  const stream = (bytes: Buffer) => {
    let at = 0;
    return { read: async () => (at >= bytes.length ? null : bytes.subarray(at, (at += 65536))) } as any;
  };
  const long = Buffer.from(JSON.stringify({ op: "fs.write", args: { content_base64: "A".repeat(6 * 1024 * 1024) } }) + "\nrest");
  const tools = new Reader(stream(long), MAX_TOOLS_LINE);
  assert.equal((await tools.line()).args.content_base64.length, 6 * 1024 * 1024);
  assert.equal(tools.carry.toString(), "rest");
  await assert.rejects(new Reader(stream(long)).line(), /head too large/);
  await assert.rejects(new Reader(stream(Buffer.from("A".repeat(MAX_TOOLS_LINE + 2) + "\n")), MAX_TOOLS_LINE).line(), /head too large/);
  // Lines one after another, from one piece.
  const two = new Reader(stream(Buffer.from('{"a":1}\n{"b":2}\n')));
  assert.deepEqual([await two.line(), await two.line(), await two.line()], [{ a: 1 }, { b: 2 }, null]);
});
