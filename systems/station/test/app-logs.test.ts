// A device's running app's logs (screens/app-logs.ts) with its processes played: lines read as a person reads them,
// crashes marked, and the bounds (line length, rate, the ring a later reader is given, the feeds a screen keeps); the
// process started by the first reader and stopped by the last. mesh-screens.test.ts reads them over the mesh.
import assert from "node:assert/strict";
import { mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AppLogFeed, AppLogs, type AppLogLine, type AppLogSaid, LineRate, MAX_LINE, RING, ReportReads, androidLogs, appLine, executableOf, foregroundOf, logcatOf, reportOf, simLogOf, simulatorLogs } from "../src/screens/app-logs.ts";

const UDID = "A119A827-41D5-49E0-9689-710DB19BF30E";
const IMAGE = `/Users/x/Library/Developer/CoreSimulator/Devices/${UDID}/data/Containers/Bundle/Application/F7/LogDemo.app/LogDemo`;
const ndjson = (eventMessage: string, messageType = "Default", processImagePath = IMAGE) => JSON.stringify({ eventMessage, messageType, timestamp: "2026-11-09 02:03:40.123456+0800", processImagePath, processID: 41189 });

test("a simulator's log line as a person reads it; its own words are none", () => {
  assert.deepEqual(simLogOf(ndjson("tick 3", "Info")), { at: "2026-11-09 02:03:40.123456+0800", level: "Info", app: "LogDemo", pid: 41189, text: "tick 3" });
  assert.equal(simLogOf('Filtering the log data using "x"'), null);
  assert.equal(simLogOf("getpwuid_r did not find a match for uid 501"), null);
});

test("a simulator's crash is marked: the Swift runtime's fatal error, an uncaught exception, a process ended on a signal", () => {
  // (what LogDemo, built for this, said on iOS 27.2 as it crashed: its fault, then libswiftCore's line)
  assert.equal(simLogOf(ndjson("LogDemo/main.swift:35: Fatal error: LogDemo crashed on purpose"))?.crash, true);
  assert.equal(simLogOf(ndjson("IOSurfaceQueryTransactionList got non-success return from kernel", "Fault"))?.crash, undefined, "a fault alone is no crash");
  assert.equal(simLogOf(ndjson("*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 3 beyond bounds for empty array'", "Error"))?.crash, true);
  const exited = simLogOf(ndjson("Process exited: <FBApplicationProcess: 0x11d2a5200; app<surf.cue.logdemo>:41189(v2FFDB2)> -> <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| domain:signal(2) code:SIGTRAP(5)>>", "Default", "/x/SpringBoard"));
  assert.deepEqual([exited?.app, exited?.pid, exited?.crash], ["surf.cue.logdemo", 41189, true]);
  // Ended by a person or the system (a kill, a terminate): said, not a crash.
  const killed = simLogOf(ndjson("Process exited: <FBApplicationProcess: 0x1; app<surf.cue.logdemo>:4(v1)> -> <RBSProcessExitContext| voluntary, status:<RBSProcessExitStatus| domain:signal(2) code:SIGKILL(9)>>", "Default", "/x/SpringBoard"));
  assert.deepEqual([killed?.app, killed?.crash], ["surf.cue.logdemo", undefined]);
  assert.equal(simLogOf(ndjson("five more ticks: 5", "Error"))?.crash, undefined, "an error is not a crash");
});

test("a line is cut at its most", () => {
  const long = simLogOf(ndjson("x".repeat(MAX_LINE * 3)))!;
  assert.equal(long.text.length, MAX_LINE);
  assert.ok(long.text.endsWith("…"));
});

test("logcat's lines, and Android's crash: FATAL EXCEPTION, a fatal signal, a process that died", () => {
  assert.deepEqual(logcatOf("11-09 02:03:40.123  1234  1250 I MyApp   : hello there"), { at: "11-09 02:03:40.123", level: "Info", app: "MyApp", pid: 1234, text: "hello there" });
  assert.equal(logcatOf("--------- beginning of main"), null);
  assert.equal(logcatOf("11-09 02:03:40.123  1234  1234 E AndroidRuntime: FATAL EXCEPTION: main")?.crash, true);
  assert.equal(logcatOf("11-09 02:03:40.123  1234  1234 E AndroidRuntime: Process: com.example.demo, PID: 1234")?.crash, true);
  assert.equal(logcatOf("11-09 02:03:40.123  1234  1260 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)")?.crash, true);
  assert.equal(logcatOf("11-09 02:03:41.000   600   700 I ActivityManager: Process com.example.demo (pid 1234) has died: fg  TOP")?.crash, true);
  assert.equal(logcatOf("11-09 02:03:40.123  1234  1250 W MyApp   : careful")?.crash, undefined);
});

test("Android's app filter: its processes' lines, and the runtime's or ActivityManager's word of it", () => {
  assert.deepEqual(foregroundOf("com.example.demo\n1234 1290\n"), { app: "com.example.demo", pids: new Set([1234, 1290]) });
  assert.deepEqual(foregroundOf("\n\n"), { app: null, pids: new Set() });
  const pids = new Set([1234]);
  assert.equal(appLine(logcatOf("11-09 02:03:40.123  1234  1250 I MyApp   : mine")!, "com.example.demo", pids), true);
  assert.equal(appLine(logcatOf("11-09 02:03:40.123  999  999 I Other   : not mine")!, "com.example.demo", pids), false);
  assert.equal(appLine(logcatOf("11-09 02:03:41.000   600   700 I ActivityManager: Process com.example.demo (pid 1234) has died: fg  TOP")!, "com.example.demo", pids), true);
  assert.equal(appLine(logcatOf("11-09 02:03:41.000   600   700 I ActivityManager: Start proc 77:com.other/u0a1")!, "com.example.demo", pids), false);
});

test("a crash report is the device's when its process ran there; another device's is none", () => {
  const head = `{"app_name":"LogDemo","timestamp":"2026-11-09 02:03:40.00 +0800","bundleID":"surf.cue.logdemo","bug_type":"309","name":"LogDemo"}\n{\n  "procPath" : "\\/Users\\/USER\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/${UDID}\\/data\\/Containers\\/Bundle\\/Application\\/F7\\/LogDemo.app\\/LogDemo",\n  "exception" : {"codes":"0x1","type":"EXC_BREAKPOINT","signal":"SIGTRAP"}\n}`;
  assert.deepEqual(reportOf(head, UDID), { app: "LogDemo", bundle: "surf.cue.logdemo", said: "EXC_BREAKPOINT (SIGTRAP)" });
  assert.equal(reportOf(head, "04382C5B-DFB9-471C-A881-31D5EDFB1EEB"), null);
  assert.equal(executableOf('{\n    CFBundleExecutable = LogDemo;\n    CFBundleIdentifier = "surf.cue.logdemo";\n}'), "LogDemo");
});

/// A feed whose process the test plays: what it was started with, its lines said by hand.
function played(rate?: LineRate, crashRate?: LineRate) {
  const runs: { said: (line: AppLogSaid) => void; ended: () => void; stopped: boolean }[] = [];
  const feed = new AppLogFeed((said, ended) => {
    const run = { said, ended, stopped: false };
    runs.push(run);
    return { stop: () => void (run.stopped = true) };
  }, rate, crashRate);
  const line = (text: string, crash = false): AppLogSaid => ({ at: "", level: "Default", app: "Demo", text, ...(crash ? { crash: true as const } : {}) });
  return { feed, runs, line };
}

/// A reader that keeps what it is told; `next` resolves when it is told lines again.
function reader() {
  const got: { lines: AppLogLine[]; dropped: number; ended: string | null } = { lines: [], dropped: 0, ended: null };
  let told = () => {};
  return {
    got,
    next: () => new Promise<void>((resolve) => (told = resolve)),
    lines: (lines: AppLogLine[], dropped: number) => {
      got.lines.push(...lines);
      got.dropped += dropped;
      told();
    },
    ended: (reason: string) => void (got.ended = reason),
  };
}

test("the process runs while someone reads: the first reader starts it, the last to leave stops it", () => {
  const { feed, runs, line } = played();
  const a = reader(), b = reader();
  const leaveA = feed.join(a);
  const leaveB = feed.join(b);
  assert.equal(runs.length, 1, "one process for both");
  runs[0]!.said(line("one"));
  assert.deepEqual([a.got.lines.map((l) => l.text), b.got.lines.map((l) => l.text)], [["one"], ["one"]]);
  leaveA();
  assert.equal(runs[0]!.stopped, false);
  leaveB();
  assert.equal(runs[0]!.stopped, true);
  assert.equal(feed.running, false);
  // A line said after it stopped is not taken.
  runs[0]!.said(line("late"));
  assert.equal(feed.tail(10).length, 1);
});

test("a later reader is given the newest lines held, at most the ring's", () => {
  const { feed, runs, line } = played(new LineRate(1e9, 1e9));
  const first = reader();
  feed.join(first);
  for (let i = 0; i < RING + 50; i++) runs[0]!.said(line(`l${i}`));
  const late = reader();
  feed.join(late);
  assert.equal(late.got.lines.length, RING);
  assert.equal(late.got.lines[0]!.text, "l50");
  assert.equal(late.got.lines.at(-1)!.seq, RING + 49);
  assert.deepEqual(feed.tail(3).map((l) => l.text), [`l${RING + 47}`, `l${RING + 48}`, `l${RING + 49}`]);
});

test("lines past the rate are dropped and counted; a crash has a rate of its own, so a flood of lines never drops one", () => {
  let now = 0;
  const { feed, runs, line } = played(new LineRate(10, 20, () => now), new LineRate(1, 2, () => now));
  const r = reader();
  feed.join(r);
  for (let i = 0; i < 30; i++) runs[0]!.said(line(`l${i}`));
  assert.equal(r.got.lines.length, 20, "the burst");
  runs[0]!.said(line("it crashed", true));
  assert.equal(r.got.lines.at(-1)!.text, "it crashed");
  now += 1000;
  runs[0]!.said(line("after a second"));
  assert.equal(r.got.lines.at(-1)!.text, "after a second");
  assert.equal(r.got.dropped, 10, "said with the next line taken");
  for (let i = 0; i < 5; i++) runs[0]!.said(line(`crash ${i}`, true));
  assert.equal(r.got.lines.filter((l) => l.crash).length, 1 + 2, "the first, then the crash bucket's burst of 2 once it refilled");
});

test("a process that ends by itself tells its readers; the next reader starts it again; a closed feed never", () => {
  const { feed, runs } = played();
  const r = reader();
  feed.join(r);
  runs[0]!.ended();
  assert.equal(r.got.ended, "the log stopped");
  feed.join(reader());
  assert.equal(runs.length, 2);
  const s = reader();
  feed.join(s);
  feed.close();
  assert.equal(runs[1]!.stopped, true);
  assert.equal(s.got.ended, "the device is gone");
  const t = reader();
  feed.join(t);
  assert.equal(runs.length, 2);
  assert.equal(t.got.ended, "the device is gone");
});

test("a screen keeps few feeds: one idle is let go of for another, none while all are read", () => {
  const made: string[] = [];
  const logs = new AppLogs((mode, app) => {
    made.push(`${mode}:${app}`);
    return () => ({ stop: () => {} });
  });
  assert.equal(logs.feed("app", "bad id;rm"), null, "an app is a bundle id or package");
  const leaves = ["a.one", "a.two", "a.three", "a.four"].map((app) => logs.feed("app", app)!.join(reader()));
  assert.equal(logs.feed("all", null), null, "all four read");
  leaves[1]!();
  assert.ok(logs.feed("all", null));
  assert.equal(logs.feed("app", "a.one"), logs.feed("app", "a.one"), "the same feed for the same filter");
  logs.close();
  assert.equal(logs.feed("app", null), null);
});

test("a simulator's log: simctl's log stream inside that device, installed apps' or one app's; its crash reports as they appear", async () => {
  const spawned: string[][] = [];
  let line: (text: string) => void = () => {};
  let started = () => {};
  const reports = mkdtempSync(join(tmpdir(), "app-logs-"));
  // The folder's watch is the test's: a file renamed into place is told as it is (fs.watch's own came late or not
  // at all on a busy CI runner, and the test waited out its 120 s).
  let appeared: (name: string) => void = () => {};
  const logs = simulatorLogs({
    watch: (_dir, heard) => {
      appeared = heard;
      return { close: () => (appeared = () => {}) };
    },
    simctl: "simctl",
    udid: UDID,
    run: async (_file, args) => (args[0] === "appinfo" ? "{\n    CFBundleExecutable = LogDemo;\n}" : ""),
    process: (args, said) => {
      spawned.push(args);
      line = said;
      started();
      return { stop: () => {} };
    },
    reports,
  });
  const r = reader();
  const leave = logs.feed("app", null)!.join(r);
  assert.deepEqual(spawned[0]!.slice(0, 9), ["simctl", "spawn", UDID, "log", "stream", "--style", "ndjson", "--level", "debug"]);
  assert.match(spawned[0]![10]!, /Containers\/Bundle\/Application/);
  line(ndjson("tick 1", "Info"));
  assert.equal(r.got.lines[0]!.text, "tick 1");
  // A report written and renamed into its place, as ReportCrash does; another device's says nothing.
  const head = (udid: string) => `{"app_name":"LogDemo","name":"LogDemo"}\n{"procPath":"\\/Users\\/USER\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/${udid}\\/data\\/x","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"}}`;
  writeFileSync(join(reports, "tmp"), head("04382C5B-DFB9-471C-A881-31D5EDFB1EEB"));
  renameSync(join(reports, "tmp"), join(reports, "Other-1.ips"));
  appeared("Other-1.ips");
  writeFileSync(join(reports, "tmp"), head(UDID));
  renameSync(join(reports, "tmp"), join(reports, "LogDemo-1.ips"));
  appeared("LogDemo-1.ips");
  // (the report read, waited for)
  while (!r.got.lines.some((l) => l.crash)) await r.next();
  const crash = r.got.lines.find((l) => l.crash)!;
  assert.deepEqual([crash.app, crash.text], ["LogDemo", "Crash report LogDemo-1.ips: EXC_BREAKPOINT (SIGTRAP)"]);
  assert.equal(r.got.lines.filter((l) => l.crash).length, 1);
  leave();
  const one = reader();
  // (its process starts once simctl has said the app's executable)
  const second = new Promise<void>((resolve) => (started = resolve));
  logs.feed("app", "surf.cue.logdemo")!.join(one);
  await second;
  assert.match(spawned[1]!.at(-1)!, /process == "LogDemo"/);
  // That app's filter: another app's report on the device says nothing, its own does.
  const other = `{"app_name":"Other","bundleID":"com.example.other"}\n{"procPath":"\\/Devices\\/${UDID}\\/x","exception":{"type":"EXC_CRASH","signal":"SIGABRT"}}`;
  const own = `{"app_name":"LogDemo","bundleID":"surf.cue.logdemo"}\n{"procPath":"\\/Devices\\/${UDID}\\/x","exception":{"type":"EXC_CRASH","signal":"SIGABRT"}}`;
  writeFileSync(join(reports, "tmp"), other);
  renameSync(join(reports, "tmp"), join(reports, "Other-2.ips"));
  appeared("Other-2.ips");
  writeFileSync(join(reports, "tmp"), own);
  renameSync(join(reports, "tmp"), join(reports, "LogDemo-2.ips"));
  appeared("LogDemo-2.ips");
  while (!one.got.lines.some((l) => l.crash)) await one.next();
  assert.deepEqual(one.got.lines.filter((l) => l.crash).map((l) => l.text), ["Crash report LogDemo-2.ips: EXC_CRASH (SIGABRT)"]);
  logs.feed("all", null)!.join(reader());
  assert.deepEqual(spawned[2]!.slice(-2), ["--level", "default"]);
  logs.close();
});

test("an Android device's log: logcat from now on through its own adb, the foreground app's lines only", async () => {
  const asked: string[][] = [];
  let line: (text: string) => void = () => {};
  let stopped = false;
  let answered: Promise<string> = Promise.resolve("");
  const logs = androidLogs({
    logcat: (args, said) => {
      asked.push(args);
      line = said;
      return { stop: () => void (stopped = true) };
    },
    run: (args) => {
      asked.push(args);
      answered = Promise.resolve("com.example.demo\n1234\n");
      return answered;
    },
    foregroundMs: 60_000,
  });
  const r = reader();
  const leave = logs.feed("app", null)!.join(r);
  assert.deepEqual(asked.find((a) => a[0] === "logcat"), ["logcat", "-v", "threadtime", "-T", "1"]);
  // (after the feed has taken the foreground app from that answer: its handler runs first)
  await answered;
  line("11-09 02:03:40.123   999   999 I Other   : not mine");
  line("11-09 02:03:40.123  1234  1250 I MyApp   : mine");
  line("11-09 02:03:40.200  1234  1234 E AndroidRuntime: FATAL EXCEPTION: main");
  assert.deepEqual(r.got.lines.map((l) => [l.text, l.crash ?? false]), [["mine", false], ["FATAL EXCEPTION: main", true]]);
  leave();
  assert.equal(stopped, true);
  // A package asked for is named in the command only as a package.
  logs.feed("app", "com.example.other")!.join(reader());
  assert.match(asked.filter((a) => a[0] === "shell").at(-1)![1]!, /^echo com\.example\.other; pidof com\.example\.other; true$/);
  logs.close();
});

test("a process that ends by itself stops all its start ran, once: a reader leaving or the device going after stops nothing more", () => {
  let stops = 0;
  let end = () => {};
  const feed = new AppLogFeed((_said, ended) => {
    end = ended;
    return { stop: () => void stops++ };
  });
  const r = reader();
  const leave = feed.join(r);
  end();
  assert.equal(stops, 1, "what the start ran beside the process (a poll, a watch) goes with it");
  assert.equal(feed.running, false);
  leave();
  feed.close();
  end();
  assert.equal(stops, 1);
  // An end said while it starts (its app could not be told): stopped once it has started.
  let early = 0;
  const failing = new AppLogFeed((_said, ended) => {
    ended();
    return { stop: () => void early++ };
  });
  const s = reader();
  failing.join(s);
  assert.deepEqual([early, s.got.ended, failing.running], [1, "the log stopped", false]);
});

test("Android's look at the foreground app stops with logcat's own end, and never runs twice at once", async () => {
  const ticks: { f: () => void; stopped: boolean }[] = [];
  let ended = () => {};
  let looks = 0;
  let answer = (_said: string) => {};
  const logs = androidLogs({
    logcat: (_args, _line, end) => {
      ended = end;
      return { stop: () => {} };
    },
    run: () => {
      looks++;
      return new Promise<string>((resolve) => (answer = resolve));
    },
    every: (_ms, f) => {
      const tick = { f, stopped: false };
      ticks.push(tick);
      return () => void (tick.stopped = true);
    },
  });
  logs.feed("app", null)!.join(reader());
  assert.equal(looks, 1);
  ticks[0]!.f();
  ticks[0]!.f();
  assert.equal(looks, 1, "a look waits for the one before");
  const answered = Promise.resolve();
  answer("com.example.demo\n1234\n");
  await answered;
  await answered;
  ticks[0]!.f();
  assert.equal(looks, 2);
  ended();
  assert.equal(ticks[0]!.stopped, true, "no look once logcat ended");
  logs.close();
});

test("a crash report heard of many times is read once, and few are read at a time", () => {
  const later: (() => void)[] = [];
  const read: string[] = [];
  const reads = new ReportReads(
    async (file) => void read.push(file),
    (_ms, f) => {
      later.push(f);
      return () => {};
    },
  );
  for (let i = 0; i < 50; i++) reads.heard("LogDemo-1.ips");
  reads.heard("not-a-report.txt");
  assert.equal(later.length, 1, "the events of one file come to one read");
  for (let i = 0; i < 100; i++) reads.heard(`Other-${i}.ips`);
  assert.equal(later.length, 16, "at most so many wait");
  for (const f of later) f();
  assert.equal(read.length, 16);
});
