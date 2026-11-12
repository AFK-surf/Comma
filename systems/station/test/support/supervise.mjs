// Runs the test command, and ends a run that stalls, saying where it stood.
//
//   node test/support/supervise.mjs <program> <args…>
//
// Past STATION_TEST_RUN_BUDGET_MS (default 6 minutes: a file watchdog.mjs ends at 3 leaves the rest of the suite, about
// a minute, its time; 0 turns it off) it prints
// every process of the run (ps) and, on macOS, the threads' stacks of each node process among them (sample):
// the runner's own, each test file's, and what a test started. Then it kills them all and exits 1. It is outside the
// run, so it sees a stall wherever it is: in a test file (watchdog.mjs names the test when the file's main thread is
// the one blocked), in the runner, or in a process's exit.
import { spawn, spawnSync } from "node:child_process";

const budget = process.env.STATION_TEST_RUN_BUDGET_MS === undefined ? 360_000 : Number(process.env.STATION_TEST_RUN_BUDGET_MS);
const [program, ...args] = process.argv.slice(2);
if (!program) throw new Error("usage: supervise.mjs <program> <args…>");

const child = spawn(program, args, { stdio: "inherit" });
child.on("error", (error) => {
  console.error(`[supervise] ${program}: ${error.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));

/// The run's processes: `child` and every descendant, as ps lists them.
function processes() {
  // ast-grep-ignore: ts-test-deadline -- bounds the diagnostic tool, not a test.
  const out = spawnSync("ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], { encoding: "utf8", timeout: 30_000 }).stdout ?? "";
  const rows = out.split("\n").map((line) => /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$/.exec(line)).filter(Boolean)
    .map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), etime: m[3], stat: m[4], command: m[5] }));
  const mine = new Map();
  const take = (pid) => {
    for (const row of rows) if (row.ppid === pid && !mine.has(row.pid)) { mine.set(row.pid, row); take(row.pid); }
  };
  const root = rows.find((row) => row.pid === child.pid);
  if (root) mine.set(root.pid, root);
  take(child.pid);
  return [...mine.values()];
}

/// The call graph of `pid`'s threads, as sample says it (macOS): all of them (a process stuck at exit waits on one
/// of the others), at most `most` lines.
function threadsOf(pid, most) {
  // ast-grep-ignore: ts-test-deadline -- bounds the diagnostic tool, not a test.
  const sampled = spawnSync("/usr/bin/sample", [String(pid), "1"], { encoding: "utf8", timeout: 30_000 });
  const lines = (sampled.stdout ?? "").split("\n");
  const graph = lines.indexOf("Call graph:");
  if (graph < 0) return `(no sample: ${(sampled.stderr ?? "").trim() || sampled.error?.message || "no output"})`;
  let end = graph + 1;
  while (end < lines.length && lines[end] !== "" && end - graph <= most) end++;
  return lines.slice(graph + 1, end).join("\n");
}

if (budget > 0 && child.pid) {
  // ast-grep-ignore: ts-test-timer -- bounds a stalled run's diagnostics, as the job's hang guard would.
  setTimeout(() => {
    const say = (text) => process.stderr.write(`${text}\n`);
    say(`[supervise] the run has taken ${budget / 1000} s: its processes, then killed`);
    const all = processes();
    for (const p of all) {
      // Node's own long options (the TLS cipher list) hide the file: drop them.
      const command = p.command.replace(/\s--[\w-]+=\S+/g, "");
      const shown = command.length > 240 ? `${command.slice(0, 80)} … ${command.slice(-150)}` : command;
      say(`  ${p.pid} (parent ${p.ppid}) ${p.etime} ${p.stat} ${shown}`);
    }
    if (process.platform === "darwin") {
      for (const p of all) {
        if (!/(^|\/)node(\s|$)/.test(p.command)) continue;
        // The runner's own process waits in its loop; a test file's is the one to read whole.
        say(`[supervise] threads of ${p.pid}:`);
        say(threadsOf(p.pid, p.pid === child.pid ? 20 : 600));
      }
    }
    for (const p of all.reverse()) {
      try { process.kill(p.pid, "SIGKILL"); } catch {}
    }
    process.exit(1);
  }, budget).unref();
}
