// A runtime process under a runner (./runner.ts), as the drivers use it: what runtime/process.rs GroupProcess was
// (a group of its own; lines of stdout to a handler, stderr to the log; write a line; SIGTERM the group, SIGKILL what
// is left after a grace), with the runner's ways of being let go and taken up again in place of the fd hand-off.
//
// Taking up: lines this station has handled are acknowledged once handled, so a next station is sent exactly the rest.
// `freeze` stops handling lines (none more is acknowledged): what a snapshot says then matches where the next station
// begins. After a crash there is no snapshot; `ackedOffset` and `linesBefore` let a driver read what the dead station
// had handled (silently) to know where things stand before the rest comes.
import { createHash } from "node:crypto";
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import { RunnerConnection, findRunner, leave, listening, runnersDir, startRunner, type Exit, type RunnerInfo } from "./runner.ts";
import { wall } from "../ops/fibers.ts";

/// A wait on another process (a grace raced against its exit): the machine's time.
const sleep = wall.sleep;

/// Lines Rust logged at debug: only with STILLFAIL_AGENTS_DEBUG set.
export const debug = (at: string, message: string, fields?: Record<string, unknown>) => {
  if (process.env.STILLFAIL_AGENTS_DEBUG) log.info(at, message, fields);
};

/// A runner id from something of the station's (a session key, a profile id): safe as a file name and short enough for
/// the socket's path (104 bytes on macOS); a hash keeps two keys that clean up the same apart.
export function runnerId(kind: "claude" | "codex", key: string): string {
  const clean = key.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 24);
  if (clean === key) return `${kind}-${clean}`;
  return `${kind}-${clean}-${createHash("sha256").update(key).digest("hex").slice(0, 10)}`;
}

/// How Rust's process.rs `describe` says an exit: its code, or the signal's name.
export function describeExit(exit: Exit): string {
  if (exit.code !== null) return String(exit.code);
  const named = ["TERM", "KILL", "INT", "HUP"];
  if (exit.signal && named.includes(exit.signal)) return `SIG${exit.signal}`;
  return exit.signal ? `signal ${exit.signal}` : "unknown";
}

export function groupAlive(pgid: number): boolean {
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/// Whether the process of a runner this station is, or was a moment ago, connected to has gone yet. Not whether a
/// runner is there: only its socket says that (runner.ts `findRunner`).
const pidAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

export { findRunner };
export const outFile = (data: string, id: string) => join(runnersDir(data), `${id}.out`);

/// The connection's socket, which runner.ts keeps to itself: its errors would otherwise go unhandled, and its closing
/// (the runner gone, or another station attached) is how this one learns of it.
function socketOf(conn: RunnerConnection): import("node:net").Socket {
  return conn["socket"];
}

export type ProcessOptions = {
  /// For the log: what it is ("claude <session>", "codex app-server <profile>").
  label: string;
  /// Each line of its stdout, in order; acknowledged once this returns.
  line: (text: string) => void;
  /// It exited (all of its output handled), as `describeExit` says, unless it was let go first; with the last lines it
  /// wrote to stderr (STDERR_TAIL of them, "" when none): what a runtime that fails as it starts says of why.
  exit: (said: string, stderr: string) => void;
};

/// How many of a runtime's last stderr lines its exit carries, and how long each may be.
const STDERR_TAIL = 3;
const STDERR_LINE = 300;

export class AgentProcess {
  readonly info: RunnerInfo;
  private conn: RunnerConnection;
  private frozen = false;
  private gone = false;
  private killing = false;
  private said: string | null = null;
  /// Its last lines of stderr, for its exit.
  private stderr: string[] = [];
  /// Its exit, described; resolved once its last line has been handled.
  readonly exited: Promise<string>;

  private constructor(info: RunnerInfo, options: ProcessOptions) {
    this.info = info;
    let resolveExit!: (said: string) => void;
    this.exited = new Promise((resolve) => (resolveExit = resolve));
    this.conn = new RunnerConnection(info, (stream, text) => {
      // Frozen: the line stays unacknowledged, for whoever takes the process up next.
      if (this.frozen) return new Promise<void>(() => {});
      const line = text.endsWith("\r") ? text.slice(0, -1) : text;
      if (stream === "err") {
        debug("agents::process", "runtime stderr", { label: options.label, line: line.slice(0, 2000) });
        if (line.trim() !== "") this.stderr = [...this.stderr, line.trim().slice(0, STDERR_LINE)].slice(-STDERR_TAIL);
      } else options.line(line);
    });
    const socket = socketOf(this.conn);
    socket.on("error", (error) => {
      if (!this.gone) log.warn("agents::process", "runner connection failed", { label: options.label, error: String(error) });
    });
    socket.on("close", () => {
      if (this.gone || this.said !== null) return;
      // Another station attached (the runner keeps one connection), or the runner itself is gone (killed): then the
      // agent went with its stdin, and nothing will say how it ended.
      if (pidAlive(info.runner)) {
        log.warn("agents::process", "another station took the runner over; letting go", { label: options.label });
        this.frozen = true;
        this.gone = true;
      } else {
        this.said = "runner gone";
        resolveExit(this.said);
        if (!this.frozen) options.exit(this.said, this.stderr.join("\n"));
      }
    });
    this.conn.exited.then((exit) => {
      if (this.said !== null) return;
      this.said = describeExit(exit);
      resolveExit(this.said);
      if (this.frozen) return;
      options.exit(this.said, this.stderr.join("\n"));
      // Read to the end: the runner may go (kill does it once what is left of the group is gone).
      if (!this.killing) this.conn.done();
    });
  }

  /// Starts `program` under a runner `id`. A runner of that id still there (a process an earlier station left and
  /// nobody took up) is ended first, as process.rs reap_stale_groups did.
  static async start(data: string, id: string, program: string, args: string[], env: Record<string, string>, cwd: string, options: ProcessOptions) {
    await endRunner(data, id, options.label);
    const info = await startRunner(data, id, program, args, env, cwd);
    return new AgentProcess(info, options);
  }

  /// Takes up the process a runner keeps: from its first line not acknowledged.
  static adopt(info: RunnerInfo, options: ProcessOptions) {
    if (!listening(info)) throw new Error(`runner ${info.id} has no socket`);
    return new AgentProcess(info, options);
  }

  get pgid() {
    return this.info.pgid;
  }

  hasExited() {
    return this.said !== null;
  }

  /// Let go (or frozen for that): no longer this station's to write to, kill or hear.
  handed() {
    return this.frozen;
  }

  /// Writes a line to its stdin (the newline added); nothing once it is let go.
  write(line: string) {
    if (this.frozen) return;
    this.conn.write(line.endsWith("\n") ? line : `${line}\n`);
  }

  /// Stops handling its lines: the next station is sent them.
  freeze() {
    this.frozen = true;
  }

  /// Lets go of it without ending it. What was handled is acknowledged first (acks go out as handlers return).
  detach() {
    this.frozen = true;
    if (this.gone) return;
    this.gone = true;
    leave(new Promise((resolve) => setImmediate(() => resolve(this.conn.detach()))));
  }

  /// Once it has exited by itself and been read to the end, its runner (told `done`) cleans up and goes, a moment after:
  /// waited for, so a process started or taken up under its id next is never that runner on its way out (taken up, it
  /// would be gone under the one taking it: its socket removed, its agent long exited). One let go stays for the next
  /// station; one still running is not this to wait for.
  async released() {
    if (this.frozen || this.said === null) return;
    for (let i = 0; i < 200 && pidAlive(this.info.runner); i++) await sleep(10);
  }

  /// SIGTERM the whole group, SIGKILL whatever is left after `graceMs`; then the runner may go.
  async kill(graceMs: number) {
    if (this.frozen) return;
    if (this.killing) {
      await this.exited;
      return;
    }
    this.killing = true;
    this.conn.signal("TERM", true);
    // The leader's exit is the signal the group is done; what outlives it, or a leader that ignores SIGTERM, is killed.
    await Promise.race([this.exited, sleep(graceMs)]);
    if (groupAlive(this.pgid)) {
      this.conn.signal("KILL", true);
      // Gone once the system has taken them away, a moment after.
      for (let i = 0; i < 100 && groupAlive(this.pgid); i++) await sleep(10);
    }
    await Promise.race([this.exited, sleep(1000)]);
    this.conn.done();
    // The runner itself goes once it has told: waited for, so a process started under its id next is not taken for it.
    for (let i = 0; i < 200 && pidAlive(this.info.runner); i++) await sleep(10);
  }
}

/// Ends a runner of this id left by an earlier station, and waits for it to go.
export async function endRunner(data: string, id: string, label: string) {
  const info = await findRunner(data, id);
  if (!info) return;
  log.warn("agents::process", "ending a runtime process left by a previous run", { label, runner: info.runner, pgid: info.pgid });
  const conn = new RunnerConnection(info, () => {});
  socketOf(conn).on("error", () => {});
  conn.signal("TERM", true);
  await Promise.race([conn.exited, sleep(2000)]);
  if (groupAlive(info.pgid)) conn.signal("KILL", true);
  await Promise.race([conn.exited, sleep(1000)]);
  conn.done();
  for (let i = 0; i < 300 && pidAlive(info.runner); i++) await sleep(10);
}

/// Where the runner will start sending stdout from: the end of what the previous station acknowledged. Asked by
/// attaching once without acknowledging anything (the runner sends from its acknowledged place on each attach).
export function ackedOffset(info: RunnerInfo, out: string): Promise<number> {
  return new Promise((resolve) => {
    const socket = createConnection(info.socket);
    let carry = "";
    let done = false;
    const finish = (at: number) => {
      if (done) return;
      done = true;
      quiet();
      socket.destroy();
      resolve(at);
    };
    const size = () => {
      try {
        return statSync(out).size;
      } catch {
        return 0;
      }
    };
    socket.on("error", () => finish(size()));
    socket.on("connect", () => socket.write(JSON.stringify({ op: "attach" }) + "\n"));
    socket.on("data", (chunk) => {
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const message = JSON.parse(carry.slice(0, i));
        carry = carry.slice(i + 1);
        if (message.op === "out" && message.stream === "out") return finish(message.at);
        // The exit comes after all output: nothing of stdout was left to send.
        if (message.op === "exit") return finish(size());
      }
    });
    // Nothing of stdout comes: all of it was acknowledged. What it had then is the place; output written just after
    // that look would come in the moment after, and says its own place.
    let quiet = wall.after(400, () => {
      const end = size();
      quiet = wall.after(150, () => finish(end));
    });
  });
}

/// The whole lines of `file` before byte `end` (a line boundary: acknowledgements are at line ends).
export function linesBefore(file: string, end: number): string[] {
  if (end <= 0) return [];
  const buf = Buffer.alloc(end);
  const fd = openSync(file, "r");
  try {
    let got = 0;
    while (got < end) {
      const n = readSync(fd, buf, got, end - got, got);
      if (n <= 0) break;
      got += n;
    }
  } finally {
    closeSync(fd);
  }
  const lines = buf.toString("utf8").split("\n");
  lines.pop();
  return lines.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
}
