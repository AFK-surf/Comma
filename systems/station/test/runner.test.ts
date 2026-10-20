// Agents under runners (src/agents/runner.ts) with the real runner binary (STILLFAIL_RUNNER or native/runner's build):
// lines in order, taken up again after a detach exactly where acknowledged, stdin, the exit after all output; a runner
// is there when its socket answers, whatever a record on disk names; one that does not start says why.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { RunnerConnection, type RunnerInfo, existingRunners, findRunner, runnersDir, startRunner as start } from "../src/agents/runner.ts";

/// The runners these tests started: one a failed test left is ended with its agent, so the file ends too.
const started: RunnerInfo[] = [];
const startRunner: typeof start = async (...args) => {
  const info = await start(...args);
  started.push(info);
  return info;
};
/// Short: the runners' sockets live under it (104 bytes at most on macOS).
const dirs: string[] = [];
const shortDir = () => {
  const dir = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "rt-") : "/tmp/rt-");
  dirs.push(dir);
  return dir;
};
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  for (const info of started) {
    for (const pid of [-info.pgid, info.runner]) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {}
    }
  }
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `f` holds (no deadline: it happens, whatever the machine's speed, or the test hangs).
const until = async (f: () => boolean) => {
  while (!f()) await sleep(20);
};

// On Windows: runner-windows.test.ts (no fifos, no sh).
test("lines in order; a station that lets go and comes back reads on where it acknowledged", { skip: process.platform === "win32" && "runner-windows.test.ts" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  // Says two lines; once let go (the fifo written), four more and marks them said; then echoes what it is sent, then
  // exits 3.
  const go = join(data, "go");
  const said = join(data, "said");
  execFileSync("/usr/bin/mkfifo", [go]);
  const script = `echo line1; echo line2; read g < '${go}'; for i in 3 4 5 6; do echo line$i; done; : > '${said}'; read x; echo got:$x; echo oops >&2; exit 3`;
  const info = await startRunner(data, "t1", "/bin/sh", ["-c", script], process.env, data);
  assert.equal(info.id, "t1");

  const first: string[] = [];
  const a = new RunnerConnection(info, (stream, text) => void (stream === "out" && first.push(text)));
  await until(() => first.length === 2);
  await a.detach();

  // Lines come meanwhile, with nobody to read them.
  writeFileSync(go, "go\n");
  await until(() => existsSync(said));
  assert.equal((await existingRunners(data)).length, 1, "the runner outlives the connection");
  const second: string[] = [];
  const b = new RunnerConnection(info, (stream, text) => void second.push(`${stream}:${text}`));
  await until(() => second.includes("out:line6"));
  b.write("hello\n");
  const exit = await b.exited;
  assert.deepEqual(exit, { code: 3, signal: null });
  const all = [...first, ...second.filter((l) => l.startsWith("out:")).map((l) => l.slice(4))];
  assert.deepEqual(all, ["line1", "line2", "line3", "line4", "line5", "line6", "got:hello"], "no line twice, none lost");
  assert.ok(second.includes("err:oops"));
  b.done();
  // Done: the runner is gone.
  while ((await existingRunners(data)).length > 0) await sleep(20);
});

/// What a runner that is no more left under `id` (it was killed; or it ran on another boot of the machine: a restart, a
/// disk restored from an archive): its record, naming a pid that is another process's by now (this test's, alive), and
/// what it had written. With `socket`, its socket's file too, as a machine's restart leaves it: nothing listens.
async function leftByARunnerThatIsGone(data: string, id: string, socket: boolean) {
  const dir = runnersDir(data);
  mkdirSync(dir, { recursive: true });
  const at = (ext: string) => join(dir, `${id}.${ext}`);
  writeFileSync(at("json"), JSON.stringify({ id, runner: process.pid, pid: process.pid, pgid: process.pid, startedAt: 1, program: "/bin/sh", args: [], socket: at("sock"), out: at("out"), err: at("err") }) + "\n");
  writeFileSync(at("out"), "what it said then\n");
  if (socket) {
    // Bound by a process that is then killed: nothing unlinks it, and nothing listens.
    const bound = spawnSync(process.execPath, ["-e", "require('node:net').createServer().listen(process.argv[1], () => process.kill(process.pid, 'SIGKILL'))", at("sock")]);
    assert.equal(bound.signal, "SIGKILL");
    assert.ok(existsSync(at("sock")));
  }
}

/// An agent that answers the first line it is given and exits: Node, on every machine.
const answersOnce = [process.execPath, ["-e", "process.stdin.once('data', (b) => { console.log('got:' + String(b).trim()); process.exit(0); })"]] as const;

for (const socket of [false, true]) {
  // A socket's file left behind is Unix's: a pipe goes with its last handle.
  test(`a record that names a pid another process has now${socket ? ", its socket's file still there," : ""} is no runner: none is found, and one starts under its id`, { skip: socket && process.platform === "win32" && "no socket file on Windows" }, async () => {
    const data = shortDir();
    await leftByARunnerThatIsGone(data, "t2", socket);
    assert.equal(await findRunner(data, "t2"), undefined, "a record whose pid is alive was taken for a runner");
    assert.deepEqual(await existingRunners(data), []);

    const info = await startRunner(data, "t2", answersOnce[0], [...answersOnce[1]], process.env, data);
    assert.notEqual(info.runner, process.pid);
    assert.equal((await findRunner(data, "t2"))?.runner, info.runner);
    const lines: string[] = [];
    const conn = new RunnerConnection(info, (stream, text) => void lines.push(`${stream}:${text}`));
    conn.write("hello\n");
    assert.deepEqual(await conn.exited, { code: 0, signal: null });
    assert.deepEqual(lines, ["out:got:hello"], "its output is its own, not what the one before left");
    conn.done();
    while ((await existingRunners(data)).length > 0) await sleep(20);
  });
}

test("a second runner is refused only while the first is there, and the station is told why; asking leaves the first with its station", async () => {
  const data = shortDir();
  const info = await startRunner(data, "t3", answersOnce[0], [...answersOnce[1]], process.env, data);
  const lines: string[] = [];
  const station = new RunnerConnection(info, (stream, text) => void lines.push(`${stream}:${text}`));
  await assert.rejects(startRunner(data, "t3", process.execPath, ["-e", ""], process.env, data), /the runner did not start: stillfail-runner: t3 is already kept by a runner/);
  // Looked for, and asked by the one refused, it is still its station's: the agent hears it and is heard.
  assert.equal((await findRunner(data, "t3"))?.runner, info.runner);
  assert.equal(JSON.parse(readFileSync(join(runnersDir(data), "t3.json"), "utf8")).runner, info.runner);
  station.write("hello\n");
  assert.deepEqual(await station.exited, { code: 0, signal: null });
  assert.deepEqual(lines, ["out:got:hello"]);
  station.done();
  while ((await existingRunners(data)).length > 0) await sleep(20);
  // Gone, its id is free again.
  const next = await startRunner(data, "t3", process.execPath, ["-e", ""], process.env, data);
  const after = new RunnerConnection(next, () => {});
  await after.exited;
  after.done();
});

test("a runner that does not start says why, though its stdout ends before it has said it", { skip: process.platform === "win32" && "a shell script as the runner" }, async () => {
  const data = shortDir();
  // A runner whose stdout is at its end a while before its reason is on stderr: the order a station can read the two in.
  const runner = join(data, "runner");
  writeFileSync(runner, "#!/bin/sh\nexec 1>&-\nsleep 0.3\necho 'stillfail-runner: x is already kept by a runner' >&2\nexit 1\n");
  chmodSync(runner, 0o755);
  const before = process.env.STILLFAIL_RUNNER;
  process.env.STILLFAIL_RUNNER = runner;
  try {
    await assert.rejects(startRunner(data, "x", "/bin/true", [], process.env, data), { message: "the runner did not start: stillfail-runner: x is already kept by a runner" });
  } finally {
    if (before === undefined) delete process.env.STILLFAIL_RUNNER;
    else process.env.STILLFAIL_RUNNER = before;
  }
});
