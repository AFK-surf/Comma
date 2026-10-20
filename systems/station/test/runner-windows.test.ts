// runner.test.ts's case on Windows, where the runner's socket is a named pipe: agents are Node scripts (no sh, no
// fifos); a station lets go (`leave`, a pipe having no one-way close) and the next reads on where it acknowledged; and
// ending an agent takes what it started with it (its job).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentProcess, findRunner } from "../src/agents/process.ts";
import { RunnerConnection, existingRunners, runnerBinary, startRunner } from "../src/agents/runner.ts";
import { keepRunnerIn } from "../src/platform/processes.ts";
import { until as upon } from "./accounts-fakes.ts";

const skip = process.platform !== "win32" && "Windows only";
/// Until `f` holds (no deadline: it happens, whatever the machine's speed, or the test hangs).
const until = (f: () => boolean | Promise<boolean>) => upon(f, "the runner's state");
const node = (script: string) => [process.execPath, ["-e", script]] as const;
const powershell = (command: string) => execFileSync("powershell.exe", ["-NoProfile", "-Command", command], { encoding: "utf8" }).trim();
/// Where a process's executable is, as the updater reads it.
const exeOf = (pid: number) => powershell(`(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=${pid}").ExecutablePath`);
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("lines in order; a station that lets go and comes back reads on where it acknowledged", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  const go = join(data, "go");
  const said = join(data, "said");
  // Says two lines; once let go (`go` there), four more and marks them said; then echoes a line it is sent, then exits 3.
  const script = `
    const fs = require("fs");
    console.log("line1"); console.log("line2");
    const wait = () => fs.existsSync(${JSON.stringify(go)}) ? more() : setTimeout(wait, 20);
    const more = () => {
      for (const i of [3, 4, 5, 6]) console.log("line" + i);
      fs.writeFileSync(${JSON.stringify(said)}, "");
      process.stdin.once("data", (b) => { console.log("got:" + String(b).trim()); console.error("oops"); process.exit(3); });
    };
    wait();`;
  const [program, args] = node(script);
  const info = await startRunner(data, "t1", program, [...args], process.env, data);
  assert.equal(info.id, "t1");
  assert.match(info.socket, /^\\\\\.\\pipe\\stillfail-runner-/);

  const first: string[] = [];
  const a = new RunnerConnection(info, (stream, text) => void (stream === "out" && first.push(text)));
  await until(() => first.length === 2);
  await a.detach();

  writeFileSync(go, "");
  await until(() => existsSync(said));
  assert.equal((await existingRunners(data)).length, 1, "the runner outlives the connection");
  assert.equal((await findRunner(data, "t1"))?.runner, info.runner, "found again: its pipe answers, and a look takes nothing over");
  const second: string[] = [];
  const b = new RunnerConnection(info, (stream, text) => void second.push(`${stream}:${text.replace(/\r$/, "")}`));
  await until(() => second.includes("out:line6"));
  b.write("hello\n");
  const exit = await b.exited;
  assert.deepEqual(exit, { code: 3, signal: null });
  const all = [...first.map((l) => l.replace(/\r$/, "")), ...second.filter((l) => l.startsWith("out:")).map((l) => l.slice(4))];
  assert.deepEqual(all, ["line1", "line2", "line3", "line4", "line5", "line6", "got:hello"], "no line twice, none lost");
  assert.ok(second.includes("err:oops"));
  b.done();
  await until(async () => (await existingRunners(data)).length === 0);
});

test("killing an agent ends what it started too", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  // Starts a Node that lives on, says its pid, and waits.
  const script = `
    const { spawn } = require("child_process");
    const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    console.log(child.pid);
    setInterval(() => {}, 1000);`;
  const [program, args] = node(script);
  const lines: string[] = [];
  let said = "";
  const proc = await AgentProcess.start(data, "k1", program, [...args], process.env as Record<string, string>, data, {
    label: "test",
    line: (text) => void lines.push(text),
    exit: (s) => void (said = s),
  });
  await until(() => lines.length === 1);
  const grandchild = Number(lines[0]);
  assert.ok(alive(grandchild));
  await proc.kill(5000);
  assert.equal(said, "SIGTERM");
  await until(() => !alive(grandchild));
  await until(async () => (await existingRunners(data)).length === 0);
});

test("runners run from a copy beside the data, which the desktop updater's sweep of its directory leaves be", { skip }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  // A release's directory of its own, as the desktop app's is to its updater.
  const release = join(data, "release");
  mkdirSync(release);
  const shipped = join(release, "stillfail-runner.exe");
  copyFileSync(runnerBinary(), shipped);
  const before = process.env.STILLFAIL_RUNNER;
  process.env.STILLFAIL_RUNNER = shipped;
  const bin = join(data, "bin");
  try {
    keepRunnerIn(bin);
    const [program, args] = node("setInterval(() => {}, 1000)");
    const info = await startRunner(data, "c1", program, [...args], process.env, data);
    assert.ok(exeOf(info.runner).toLowerCase().startsWith(bin.toLowerCase()), "the runner runs from its copy");

    // The updater before it replaces the app: every process whose executable is under the app's directory ends.
    powershell(`Get-CimInstance -ClassName Win32_Process | ? {$_.Path -and $_.Path.StartsWith('${release}', 'CurrentCultureIgnoreCase')} | % { Stop-Process -Id $_.ProcessId }`);
    assert.ok(alive(info.runner) && alive(info.pid), "runner and agent outlive the sweep");
    assert.equal((await findRunner(data, "c1"))?.runner, info.runner, "a station after the update finds it");

    // Another release's copy no runner runs from goes; the one running stays.
    const stale = join(bin, "stillfail-runner-0123456789abcdef.exe");
    copyFileSync(shipped, stale);
    keepRunnerIn(bin);
    assert.ok(!existsSync(stale));
    assert.ok(existsSync(exeOf(info.runner)));

    const c = new RunnerConnection(info, () => {});
    process.kill(info.pid);
    await c.exited;
    c.done();
    await until(async () => (await existingRunners(data)).length === 0);
  } finally {
    if (before === undefined) delete process.env.STILLFAIL_RUNNER;
    else process.env.STILLFAIL_RUNNER = before;
  }
});
