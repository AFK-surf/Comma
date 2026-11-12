// Names a test file that stalls, and ends it (loaded with `node --import` before the tests).
//
// A test that awaits forever is cut by --test-timeout (2 minutes), and the runner names it. One that blocks the event
// loop (a synchronous call that never returns) is not: the file's timers never fire, so its results never reach the
// runner; and the runner reports files in name order, so every later file is held back too. The job's log then ends
// at the last test of the file before it, until the job is cancelled. A worker thread, with an event loop of its own,
// counts the file's time. Past STATION_TEST_FILE_BUDGET_MS (default 3 minutes: after --test-timeout, so an await that
// hangs is the runner's to name; the slowest file takes under a minute; 0 turns it off) it writes to stderr the file,
// the test it is in, and on macOS the main thread's stack (`sample`), then kills the process: the runner reports the
// file as failed and goes on to the rest. supervise.mjs bounds the whole run from outside, later.
//
// A file's process ends on its own once its tests are done and nothing holds its event loop: not by process.exit()
// (--test-force-exit), which on Node 24 can wait forever for a V8 worker thread that waits for the main thread
// (nodejs/node#64274). A file still running STATION_TEST_GRACE_MS (default 30 seconds: under the whole suite's load
// a file's processes and pipes may take seconds to go) after its tests is one that left something open: what it is
// (process.getActiveResourcesInfo) goes to stderr, and the process is killed: the runner reports the file as failed.
import { spawnSync } from "node:child_process";
import { existsSync, writeSync } from "node:fs";
import { isMainThread, parentPort, Worker, workerData } from "node:worker_threads";

const budget = process.env.STATION_TEST_FILE_BUDGET_MS === undefined ? 180_000 : Number(process.env.STATION_TEST_FILE_BUDGET_MS);
const GRACE_MS = process.env.STATION_TEST_GRACE_MS === undefined ? 30_000 : Number(process.env.STATION_TEST_GRACE_MS);

if (isMainThread) {
  // A test file's process (the runner's own has no NODE_TEST_CONTEXT).
  if (process.env.NODE_TEST_CONTEXT && budget > 0) {
    const { after, afterEach, beforeEach } = await import("node:test");
    const file = process.argv[1];
    const worker = new Worker(new URL(import.meta.url), { workerData: { stationTestWatchdog: true, budget, file } });
    worker.unref();
    beforeEach((t) => worker.postMessage(t.fullName));
    afterEach(() => worker.postMessage(null));
    after(() => {
      // ast-grep-ignore: ts-test-timer -- names what a finished test file left open; unreferenced, so a clean file ends before it.
      const grace = setTimeout(() => {
        writeSync(2, `[watchdog] ${file} still runs ${GRACE_MS / 1000} s after its tests, holding: ${process.getActiveResourcesInfo().join(", ")}: killed\n`);
        // Not process.exit(): that is the call that can wait forever. The runner reports the file as failed.
        process.kill(process.pid, "SIGKILL");
      }, GRACE_MS);
      grace.unref();
    });
  }
} else if (workerData?.stationTestWatchdog) {
  // The station's own worker threads (src/read/pool.ts) load this file too, as workers take the process's --import:
  // only the thread made above is the watchdog.
  let test = null;
  parentPort.on("message", (name) => {
    test = name;
  });
  // The main thread may be blocked: fd 2 directly, not process.stderr (which it would have to pump).
  const say = (text) => writeSync(2, text);
  // ast-grep-ignore: ts-test-timer -- bounds a stalled test file's diagnostics, as the job's hang guard would.
  setTimeout(() => {
    const where = test === null ? "between tests (or before the first)" : `in "${test}"`;
    say(`[watchdog] ${workerData.file} has run ${workerData.budget / 1000} s, ${where}: killed\n`);
    if (process.platform === "darwin" && existsSync("/usr/bin/sample")) {
      // ast-grep-ignore: ts-test-deadline -- bounds the diagnostic tool, not a test.
      const sampled = spawnSync("/usr/bin/sample", [String(process.pid), "1"], { encoding: "utf8", timeout: 30_000 });
      // The main thread's call graph: the first thread after "Call graph:", up to the next.
      const lines = (sampled.stdout ?? "").split("\n");
      const graph = lines.indexOf("Call graph:");
      const isThread = (line) => /^\s+\d+ Thread_/.test(line);
      const start = graph < 0 ? 0 : graph;
      let end = start + 1;
      while (end < lines.length && (end === start + 1 || !isThread(lines[end])) && end - start < 200) end++;
      say(`${lines.slice(start, end).join("\n")}\n`);
    }
    process.kill(process.pid, "SIGKILL");
  }, workerData.budget);
}
