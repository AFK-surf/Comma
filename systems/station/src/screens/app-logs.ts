// The running app's logs beside a device's picture: an iOS Simulator's `log stream` inside the device, an Android
// device's `logcat`, each pinned to its device (a simulator's UDID, adb's `-s <serial>`). Ported from still.fail's
// station/src/screens/sim-debug.ts (afk/main): its `log stream --style ndjson` and predicate (only apps a person installed,
// and of those only what the app's own code, Foundation's NSLog and an error say), its `logOf` and its `logStream`.
// Deviations: still.fail polls a held list from its admin API; here a viewer reads a stream on the mesh
// (mesh/screens.ts `/screens/<id>/logs`), the process runs only while someone reads, and lines are bounded on the
// way in (rate, length) and to each reader. Crashes are marked here (still.fail has none): the Swift runtime's and
// Objective-C's last words, SpringBoard's word of an app's process ending on a signal, a crash report (.ips) of the
// device appearing in DiagnosticReports, and Android's FATAL EXCEPTION, fatal signal and dead process.
//
// Bounds, per feed (one per screen and filter; at most MAX_FEEDS a screen):
// - a line is cut at MAX_LINE characters;
// - lines come in at most RATE a second (a burst of BURST), the rest counted and said as dropped; crash lines have a
//   bucket of their own (CRASH_RATE), so a flood of lines never drops one and a flood of them never drowns the rest;
// - the newest RING lines are held, for a reader that joins later;
// - a reader that reads slower than lines come holds at most READER_QUEUE, the oldest dropped and counted.
import { type ChildProcess, spawn } from "node:child_process";
import { type FSWatcher, existsSync, watch } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";

/// One line of an app's log as a viewer shows it. `seq` counts from the feed's first line; `crash`: it says the app
/// crashed or its process ended on a signal.
export type AppLogLine = { seq: number; at: string; level: string; app: string; pid?: number; text: string; crash?: true };
export type AppLogSaid = Omit<AppLogLine, "seq">;
/// `app`: the app on the device (installed apps on a simulator, the foreground app on Android, or the one asked for);
/// `all`: the whole device, at its default level.
export type AppLogMode = "app" | "all";

export const MAX_LINE = 2000;
export const RATE = 200;
export const BURST = 400;
export const RING = 1000;
export const READER_QUEUE = 2000;
export const CRASH_RATE = 10;
const CRASH_BURST = 50;
/// Feeds one screen keeps (each filter, each app asked for): the one idle longest goes past it.
const MAX_FEEDS = 4;
/// How often Android's foreground app and its processes are looked at again while its `app` feed runs.
const FOREGROUND_MS = 2000;
/// What of a crash report is read to tell its device: its header and `procPath` are at its start.
const REPORT_HEAD = 64 * 1024;
/// How long after a report's file is heard of it is read, its reads at most at once, and the files remembered as read.
const REPORT_SETTLE_MS = 200;
const REPORTS_PENDING = 16;
const REPORTS_SEEN = 256;
export const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;

/// A process whose stdout is read line by line (still.fail's `LogStream`).
export type LogProcess = (args: string[], line: (text: string) => void, ended: () => void) => { stop: () => void };
/// What starts a feed's lines: gives the function that stops them.
export type LogStart = (said: (line: AppLogSaid) => void, ended: () => void) => { stop: () => void };

export const logProcess: LogProcess = (args, line, ended) =>
  childLines(spawn(args[0]!, args.slice(1), { stdio: ["ignore", "pipe", "ignore"], windowsHide: true }), line, ended);

/// A child's stdout line by line, until it ends; the function that ends it.
export function childLines(child: ChildProcess, line: (text: string) => void, ended: () => void): { stop: () => void } {
  let rest = "";
  child.stdout!.setEncoding("utf8");
  child.stdout!.on("data", (chunk: string) => {
    const parts = (rest + chunk).split("\n");
    rest = parts.pop()!;
    // (a line with no end in sight is not held without bound)
    if (rest.length > MAX_LINE * 4) rest = rest.slice(0, MAX_LINE * 4);
    for (const part of parts) line(part);
  });
  let over = false;
  const end = () => {
    if (over) return;
    over = true;
    ended();
  };
  child.on("error", end);
  child.on("close", end);
  return { stop: () => void child.kill() };
}

const cut = (text: string) => (text.length > MAX_LINE ? `${text.slice(0, MAX_LINE - 1)}…` : text);

/// Whether a line's words say its app crashed: the Swift runtime's, Objective-C's uncaught exception, an assertion,
/// a bad access, Android's runtime and libc's.
export function crashOf(text: string): boolean {
  return /\bFatal error: |Terminating app due to uncaught exception|\*\*\* Assertion failure in |\bEXC_BAD_ACCESS\b|\bEXC_CRASH\b|\bFATAL EXCEPTION\b|\bFatal signal \d+\b|^\*\*\* \*\*\* \*\*\*/.test(text);
}

/// SpringBoard's word that an app's process ended (`Process exited: <… app<id>:pid …> -> <… status:<… domain:signal(2)
/// code:SIGTRAP(5)>>`): the app, and whether it was a crash (a signal but the kill and terminate a person or the system
/// ends an app with). Null: not such a word.
export function exitOf(text: string): { app: string; pid?: number; crash: boolean } | null {
  const m = /^Process exited: <[^>]*app<([^>:]+)>(?::(\d+))?[^>]*> -> (.*)$/s.exec(text);
  if (m === null) return null;
  const signal = /domain:signal\(\d+\) code:(SIG[A-Z]+)/.exec(m[3]!)?.[1];
  return { app: m[1]!, ...(m[2] ? { pid: Number(m[2]) } : {}), crash: signal !== undefined && signal !== "SIGKILL" && signal !== "SIGTERM" };
}

/// A line of `log stream --style ndjson` as a person reads it; null for what is not one (its own words at its start).
/// still.fail's `logOf`, with its process id and crash mark.
export function simLogOf(line: string): AppLogSaid | null {
  let e: any;
  try {
    e = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof e?.eventMessage !== "string") return null;
  const image = typeof e.processImagePath === "string" ? e.processImagePath : "";
  const text: string = e.eventMessage;
  const exit = exitOf(text);
  // (a fault alone is no crash: the system's daemons say many)
  const crash = (exit?.crash ?? false) || crashOf(text);
  return {
    at: typeof e.timestamp === "string" ? e.timestamp : "",
    level: typeof e.messageType === "string" ? e.messageType : "",
    app: exit?.app ?? image.slice(image.lastIndexOf("/") + 1),
    // (SpringBoard's word of an app's end: the app's process, not SpringBoard's)
    ...(exit?.pid !== undefined ? { pid: exit.pid } : Number.isSafeInteger(e.processID) ? { pid: e.processID as number } : {}),
    text: cut(text),
    ...(crash ? { crash: true as const } : {}),
  };
}

const LOGCAT = /^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.*?)\s*: (.*)$/s;
const LEVELS: Record<string, string> = { V: "Verbose", D: "Debug", I: "Info", W: "Warning", E: "Error", F: "Fatal", A: "Fatal" };

/// A line of `logcat -v threadtime` (`11-09 02:03:40.123  1234  1250 E AndroidRuntime: FATAL EXCEPTION: main`); null
/// for what is not one (`--------- beginning of main`). `app` is its tag.
export function logcatOf(line: string): AppLogSaid | null {
  const m = LOGCAT.exec(line.replace(/\r$/, ""));
  if (m === null) return null;
  const [, at, pid, , level, tag, text] = m;
  const died = tag === "ActivityManager" && /^Process \S+ \(pid \d+\) has died/.test(text!);
  const crash = crashOf(text!) || level === "F" || level === "A" || (tag === "AndroidRuntime" && level === "E" && /^(FATAL EXCEPTION|Process: )/.test(text!));
  return { at: at!, level: LEVELS[level!]!, app: tag!, pid: Number(pid), text: cut(text!), ...(crash || died ? { crash: true as const } : {}) };
}

/// Lines in at most `rate` a second, a burst of `burst`: a token bucket on the wall's clock.
export class LineRate {
  readonly #rate: number;
  readonly #burst: number;
  readonly #now: () => number;
  #tokens: number;
  #at: number;
  constructor(rate = RATE, burst = BURST, now: () => number = wall.now) {
    this.#rate = rate;
    this.#burst = burst;
    this.#now = now;
    this.#tokens = burst;
    this.#at = now();
  }
  take(): boolean {
    const now = this.#now();
    this.#tokens = Math.min(this.#burst, this.#tokens + ((now - this.#at) / 1000) * this.#rate);
    this.#at = now;
    if (this.#tokens < 1) return false;
    this.#tokens--;
    return true;
  }
}

/// One who reads a feed: told each line (in order), and how many were dropped before the next.
export type AppLogReader = { lines(lines: AppLogLine[], dropped: number): void; ended(reason: string): void };

/// One screen's lines of one filter: its process runs while someone reads it, its newest lines held for whoever joins.
export class AppLogFeed {
  readonly #start: LogStart;
  readonly #rate: LineRate;
  readonly #crashRate: LineRate;
  readonly #ring: AppLogLine[] = [];
  readonly #readers = new Set<AppLogReader>();
  #next = 0;
  #dropped = 0;
  #running: { stop: () => void } | null = null;
  #closed = false;
  /// When the last reader left (or it was made): the feed idle longest goes first.
  idleSince = wall.now();

  constructor(start: LogStart, rate: LineRate = new LineRate(), crashRate: LineRate = new LineRate(CRASH_RATE, CRASH_BURST)) {
    this.#start = start;
    this.#rate = rate;
    this.#crashRate = crashRate;
  }

  get readers(): number {
    return this.#readers.size;
  }

  get running(): boolean {
    return this.#running !== null;
  }

  /// The newest `n` lines held (at most RING).
  tail(n: number): AppLogLine[] {
    return n <= 0 ? [] : this.#ring.slice(-n);
  }

  /// `reader` told the lines held, then each as it comes, until the function returned is called. The first reader
  /// starts the process; the last to leave stops it.
  join(reader: AppLogReader): () => void {
    if (this.#closed) {
      reader.ended("the device is gone");
      return () => {};
    }
    this.#readers.add(reader);
    if (this.#ring.length > 0) reader.lines([...this.#ring], 0);
    if (this.#running === null) this.#run();
    return () => {
      if (!this.#readers.delete(reader)) return;
      if (this.#readers.size > 0) return;
      this.idleSince = wall.now();
      this.#running?.stop();
      this.#running = null;
    };
  }

  /// The device went: its readers are told, its process stopped, and its lines let go of.
  close(reason = "the device is gone") {
    if (this.#closed) return;
    this.#closed = true;
    this.#running?.stop();
    this.#running = null;
    for (const reader of [...this.#readers]) reader.ended(reason);
    this.#readers.clear();
    this.#ring.length = 0;
  }

  /// Starts the process. What it is stopped by is stopped once, whichever way it ends: asked (the last reader left,
  /// the device went) or of itself, all of it (the process, and what its start runs beside it: Android's look at the
  /// foreground app, a simulator's watch of its crash reports). Its end may come while it starts.
  #run() {
    let started: { stop: () => void } | null = null;
    let stopped = false;
    const running = {
      stop: () => {
        if (stopped) return;
        stopped = true;
        started?.stop();
      },
    };
    this.#running = running;
    started = this.#start(
      (said) => {
        if (this.#running === running) this.#said(said);
      },
      () => {
        running.stop();
        // Its own end, not one asked for: its readers are told, and the next to join starts it again.
        if (this.#running !== running) return;
        this.#running = null;
        for (const reader of [...this.#readers]) reader.ended("the log stopped");
        this.#readers.clear();
        this.idleSince = wall.now();
      },
    );
    // (it ended while it started: what it started goes now)
    if (stopped) started.stop();
  }

  #said(said: AppLogSaid) {
    if (this.#closed) return;
    if (!(said.crash ? this.#crashRate : this.#rate).take()) {
      this.#dropped++;
      return;
    }
    const line: AppLogLine = { seq: this.#next++, ...said };
    this.#ring.push(line);
    if (this.#ring.length > RING) this.#ring.splice(0, this.#ring.length - RING);
    const dropped = this.#dropped;
    this.#dropped = 0;
    for (const reader of this.#readers) reader.lines([line], dropped);
  }
}

/// A screen's feeds, one for each filter and app asked: at most MAX_FEEDS, the one idle longest let go of past it.
export class AppLogs {
  readonly #feeds = new Map<string, AppLogFeed>();
  readonly #make: (mode: AppLogMode, app: string | null) => LogStart;
  #closed = false;

  constructor(make: (mode: AppLogMode, app: string | null) => LogStart) {
    this.#make = make;
  }

  feed(mode: AppLogMode, app: string | null): AppLogFeed | null {
    if (this.#closed || (app !== null && !BUNDLE_ID.test(app))) return null;
    const key = `${mode}\n${app ?? ""}`;
    const had = this.#feeds.get(key);
    if (had) return had;
    if (this.#feeds.size >= MAX_FEEDS) {
      const idle = [...this.#feeds].filter(([, f]) => f.readers === 0).sort(([, a], [, b]) => a.idleSince - b.idleSince)[0];
      if (idle === undefined) return null;
      idle[1].close();
      this.#feeds.delete(idle[0]);
    }
    const feed = new AppLogFeed(this.#make(mode, app));
    this.#feeds.set(key, feed);
    return feed;
  }

  /// The device went, or the station stops.
  close() {
    this.#closed = true;
    for (const feed of this.#feeds.values()) feed.close();
    this.#feeds.clear();
  }
}

/// still.fail's predicate: what apps a person installed say of their own, Foundation's NSLog and any error; with the
/// Swift runtime's last words (its `Fatal error`), CoreFoundation's of an uncaught exception, and SpringBoard's word
/// that an app's process ended.
const INSTALLED = '"/Containers/Bundle/Application/"';
const APP_PREDICATE = `(processImagePath CONTAINS ${INSTALLED} AND (senderImagePath CONTAINS ${INSTALLED} OR senderImagePath ENDSWITH "/Foundation" OR senderImagePath ENDSWITH "/libswiftCore.dylib" OR messageType == error OR messageType == fault OR eventMessage BEGINSWITH "*** Terminating app due to uncaught exception")) OR (process == "SpringBoard" AND eventMessage BEGINSWITH "Process exited: ")`;

/// The predicate of one app, by its executable's name, and its process's end.
const onePredicate = (bundle: string, executable: string) =>
  `(process == "${executable}" AND (messageType == default OR messageType == error OR messageType == fault OR subsystem == "${bundle}" OR senderImagePath ENDSWITH "/${executable}")) OR (process == "SpringBoard" AND eventMessage BEGINSWITH "Process exited: " AND eventMessage CONTAINS "app<${bundle}>")`;

/// An executable's name as `simctl appinfo` says it (an old-style plist: `CFBundleExecutable = LogDemo;`).
export function executableOf(appinfo: string): string | null {
  const name = /\bCFBundleExecutable = "?([^";\n]+)"?;/.exec(appinfo)?.[1]?.trim();
  return name && /^[A-Za-z0-9 ._-]{1,128}$/.test(name) ? name : null;
}

/// A crash report's app and what it ended with, when it is one of the device `udid`'s (its `procPath` under the
/// device's folder); null otherwise. `head`: its first REPORT_HEAD bytes.
export function reportOf(head: string, udid: string): { app: string; bundle: string | null; said: string } | null {
  if (!head.includes(`/Devices/${udid}/`) && !head.includes(`\\/Devices\\/${udid}\\/`)) return null;
  const first = head.slice(0, head.indexOf("\n") >>> 0);
  let app = "";
  let bundle: string | null = null;
  try {
    const h = JSON.parse(first);
    app = typeof h.app_name === "string" ? h.app_name : typeof h.name === "string" ? h.name : "";
    bundle = typeof h.bundleID === "string" ? h.bundleID : null;
  } catch {
    // (an older report's header is not JSON: its name and bundle stay unknown)
  }
  const type = /"type"\s*:\s*"(EXC_[A-Z_]+)"/.exec(head)?.[1];
  const signal = /"signal"\s*:\s*"(SIG[A-Z]+)"/.exec(head)?.[1];
  return { app, bundle, said: [type, signal && `(${signal})`].filter(Boolean).join(" ") };
}

export type Run = (file: string, args: string[]) => Promise<string>;

/// A simulator's feeds: `simctl spawn <udid> log stream` (one app's, or all at the default level), and its crash reports
/// as they appear.
/// What tells the files that appear in a folder by name (`fs.watch`; a test's own, which it tells itself).
export type WatchDir = (dir: string, heard: (name: string) => void) => { close: () => void };
const watchDir: WatchDir = (dir, heard) => {
  const watcher: FSWatcher = watch(dir, (_event, name) => {
    if (typeof name === "string") heard(name);
  });
  watcher.on("error", () => watcher.close());
  return { close: () => watcher.close() };
};

export function simulatorLogs(o: { simctl: string; udid: string; run: Run; process?: LogProcess; reports?: string | null; readHead?: (file: string) => Promise<string>; watch?: WatchDir }): AppLogs {
  const spawnLog = o.process ?? logProcess;
  const reports = o.reports === undefined ? join(homedir(), "Library", "Logs", "DiagnosticReports") : o.reports;
  const readHead = o.readHead ?? headOf;
  return new AppLogs((mode, app) => (said, ended) => {
    let stopped = false;
    let child: { stop: () => void } | null = null;
    const watcher = reports === null ? null : watchReports(o.watch ?? watchDir, reports, o.udid, readHead, (report, file) => {
      // One app's filter: its own reports only (one whose header names no bundle is not known to be its).
      if (stopped || (app !== null && report.bundle !== app)) return;
      said({ at: localTime(wall.now()), level: "Fault", app: report.app, text: cut(`Crash report ${file}${report.said ? `: ${report.said}` : ""}`), crash: true });
    });
    const begin = (predicate: string | null, level: string) => {
      if (stopped) return;
      const args = [o.simctl, "spawn", o.udid, "log", "stream", "--style", "ndjson", "--level", level, ...(predicate ? ["--predicate", predicate] : [])];
      child = spawnLog(args, (line) => {
        const one = simLogOf(line);
        if (one !== null) said(one);
      }, ended);
      log.info("screens", "a simulator's app logs followed", { udid: o.udid, mode });
    };
    if (mode === "all") begin(null, "default");
    else if (app === null) begin(APP_PREDICATE, "debug");
    else
      void o.run(o.simctl, ["appinfo", o.udid, app]).then(
        (info) => {
          const executable = executableOf(info);
          if (executable === null) return ended();
          begin(onePredicate(app, executable), "debug");
        },
        () => ended(),
      );
    return {
      stop: () => {
        if (stopped) return;
        stopped = true;
        watcher?.close();
        child?.stop();
      },
    };
  });
}

/// A time as `log stream` says its own (`2026-11-09 02:12:06.192000+0800`): this machine's, as the device's lines are.
export function localTime(ms: number): string {
  const d = new Date(ms);
  const two = (n: number) => String(n).padStart(2, "0");
  const off = -d.getTimezoneOffset();
  const zone = `${off < 0 ? "-" : "+"}${two(Math.floor(Math.abs(off) / 60))}${two(Math.abs(off) % 60)}`;
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3, "0")}000${zone}`;
}

async function headOf(file: string): Promise<string> {
  const f = await open(file, "r");
  try {
    const b = Buffer.alloc(REPORT_HEAD);
    const { bytesRead } = await f.read(b, 0, REPORT_HEAD, 0);
    return b.toString("utf8", 0, bytesRead);
  } finally {
    await f.close();
  }
}

/// The reports a watch has had and is about to read: each file read once, at most REPORTS_PENDING read at a time, a
/// file's events past the first coming to nothing (a report is written, then renamed into its place: several events).
export class ReportReads {
  readonly #seen = new Set<string>();
  readonly #pending = new Set<string>();
  readonly #read: (file: string) => Promise<void>;
  readonly #after: (ms: number, f: () => void) => () => void;
  #closed = false;
  #cancels = new Set<() => void>();

  constructor(read: (file: string) => Promise<void>, after: (ms: number, f: () => void) => () => void = wall.after) {
    this.#read = read;
    this.#after = after;
  }

  heard(file: string) {
    if (this.#closed || !file.endsWith(".ips") || this.#seen.has(file) || this.#pending.has(file) || this.#pending.size >= REPORTS_PENDING) return;
    this.#pending.add(file);
    // (read once it is whole enough to tell its device)
    const cancel = this.#after(REPORT_SETTLE_MS, () => {
      this.#cancels.delete(cancel);
      void this.#read(file)
        .catch(() => {})
        .finally(() => {
          this.#pending.delete(file);
          this.#seen.add(file);
          if (this.#seen.size > REPORTS_SEEN) this.#seen.delete(this.#seen.values().next().value!);
        });
    });
    this.#cancels.add(cancel);
  }

  close() {
    this.#closed = true;
    for (const cancel of this.#cancels) cancel();
    this.#cancels.clear();
  }
}

/// Crash reports (.ips) that appear in `dir` while it is watched, each told once when it is the device's.
function watchReports(watchFiles: WatchDir, dir: string, udid: string, readHead: (file: string) => Promise<string>, heard: (report: { app: string; bundle: string | null; said: string }, file: string) => void): { close: () => void } | null {
  if (!existsSync(dir)) return null;
  const reads = new ReportReads(async (file) => {
    const report = reportOf(await readHead(join(dir, file)), udid);
    if (report !== null) heard(report, file);
  });
  try {
    const watcher = watchFiles(dir, (name) => reads.heard(name));
    return {
      close: () => {
        reads.close();
        watcher.close();
      },
    };
  } catch {
    reads.close();
    return null;
  }
}

/// What tells Android's foreground app and its processes: one shell command, its package on the first line and its
/// pids on the next. A package asked for is checked here and named in the command only once it is.
export const foregroundScript = (app: string | null) =>
  app === null
    ? `p=$(dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity' | sed -E 's/.* ([A-Za-z0-9._]+)\\/.*/\\1/'); echo "$p"; [ -n "$p" ] && pidof "$p"; true`
    : `echo ${app}; pidof ${app}; true`;

/// The package and pids that answer says.
export function foregroundOf(said: string): { app: string | null; pids: Set<number> } {
  const [first = "", second = ""] = said.split("\n").map((l) => l.trim());
  const app = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(first) ? first : null;
  return { app, pids: new Set(second.split(/\s+/).filter((p) => /^\d+$/.test(p)).map(Number)) };
}

/// Whether a logcat line is the app's: one of its processes', or the runtime's or ActivityManager's word of it.
export function appLine(line: AppLogSaid, app: string | null, pids: ReadonlySet<number>): boolean {
  if (line.pid !== undefined && pids.has(line.pid)) return true;
  if (app === null) return false;
  return (line.app === "ActivityManager" || line.app === "AndroidRuntime" || line.app === "DEBUG" || line.app === "libc") && line.text.includes(app);
}

/// An Android device's feeds, all through its own adb pinned to its serial (`adb -s <serial>`): `logcat -v threadtime`
/// from now on; the `app` filter keeps the foreground app's lines (or the package asked for), looked at again every
/// FOREGROUND_MS while it runs.
export function androidLogs(o: { logcat: LogProcess; run: (args: string[]) => Promise<string>; foregroundMs?: number; every?: (ms: number, f: () => void) => () => void }): AppLogs {
  const every = o.every ?? wall.every;
  return new AppLogs((mode, app) => (said, ended) => {
    let stopped = false;
    let current: { app: string | null; pids: Set<number> } = { app, pids: new Set() };
    let stopLooking = () => {};
    // One look at a time: one adb takes longer than the period, the next waits for the next tick.
    let looking = false;
    const look = () => {
      if (stopped || looking) return;
      looking = true;
      void o
        .run(["shell", foregroundScript(app)])
        .then(
          (answer) => {
            if (!stopped) current = foregroundOf(answer);
          },
          () => {},
        )
        .finally(() => (looking = false));
    };
    if (mode === "app") {
      look();
      stopLooking = every(o.foregroundMs ?? FOREGROUND_MS, look);
    }
    let child: { stop: () => void } | null = null;
    child = o.logcat(["logcat", "-v", "threadtime", "-T", "1"], (text) => {
      const one = logcatOf(text);
      if (one === null || stopped) return;
      if (mode === "app" && !appLine(one, current.app, current.pids)) return;
      said(one);
    }, ended);
    return {
      stop: () => {
        if (stopped) return;
        stopped = true;
        stopLooking();
        child?.stop();
      },
    };
  });
}
