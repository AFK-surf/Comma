// Agent processes kept by runners (native/runner, docs/station-ts-native.md §1): each claude or codex process is the
// child of a `stillfail-runner` that outlives this station, restarting or crashing. Starting one gives a handle; a
// station starting finds those of before (<data>/run/runners/*.json) and takes them up again where it stopped reading:
// what it has handled is acknowledged line by line, so nothing is read twice and nothing is lost.
//
// A runner is there when its socket answers, and only then. Its record on disk does not say so: a runner that was
// killed leaves it, and so does another boot of the machine (a restart, a disk restored from an archive), and the pid it
// names is by then any process's. On Windows the socket is a named pipe (`\\.\pipe\…`, its `socket`), not a file:
// only a connection says it is there.
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { join } from "node:path";
import { runtimeDir } from "../ops/files.ts";
import { platform } from "../platform/index.ts";
import { runnerBinary } from "../platform/processes.ts";

export type RunnerInfo = {
  id: string;
  runner: number;
  pid: number;
  pgid: number;
  startedAt: number;
  program: string;
  args: string[];
  socket: string;
};

export type Exit = { code: number | null; signal: string | null };

/// The runner binary: STILLFAIL_RUNNER, else beside the station's code in a release, else where cargo built it.
export { runnerBinary };

export const runnersDir = (data: string) => join(runtimeDir(data), "runners");

/// Whether a runner's socket is there to attach to (one on its way out has removed it). A pipe cannot be looked at
/// (see above): its record, which goes with it, says so then.
export const listening = (info: RunnerInfo) => !platform.runnerSocketVisible || existsSync(info.socket);

/// Starts `program` under a runner, its environment `env` (the agent's whole environment), in `cwd`.
export function startRunner(data: string, id: string, program: string, args: string[], env: NodeJS.ProcessEnv, cwd: string): Promise<RunnerInfo> {
  return new Promise((resolve, reject) => {
    const child = spawn(runnerBinary(), ["--dir", runnersDir(data), "--id", id, "--cwd", cwd, "--", program, ...args], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (b) => (out += b));
    child.stderr.on("data", (b) => (err += b));
    child.on("error", reject);
    const stderrEnded = new Promise<void>((done) => child.stderr.once("close", () => done()));
    // The ready line comes before the runner lets go of its stdout; a runner that fails says why and exits non-zero.
    child.stdout.on("end", () => {
      const line = out.split("\n").find((l) => l.startsWith("{"));
      if (line) {
        const ready = JSON.parse(line);
        if (ready.ready) return resolve(ready as RunnerInfo);
      }
      // Why is on its stderr, which ends as it exits: read to its end first (stdout's end can come before it is read).
      void stderrEnded.then(() => reject(new Error(`the runner did not start: ${err.trim() || out.trim() || "it said nothing"}`)));
    });
    child.unref();
  });
}

/// Whether a runner listens on `socket`. A connection that says nothing is all it takes, and a runner leaves it be.
export function runnerAnswers(socket: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = createConnection(socket);
    probe.once("connect", () => {
      probe.destroy();
      resolve(true);
    });
    probe.once("error", () => resolve(false));
  });
}

const recordOf = (file: string): RunnerInfo | null => {
  try {
    const info = JSON.parse(readFileSync(file, "utf8")) as RunnerInfo;
    return typeof info?.socket === "string" ? info : null;
  } catch {
    return null;
  }
};

/// The runner of this id, when one is there (its socket answers; one on its way out has let it go). Asked of one a
/// station is not attached to: a runner from before this look closes the connection it had for any new one.
export async function findRunner(data: string, id: string): Promise<RunnerInfo | undefined> {
  const info = recordOf(join(runnersDir(data), `${id}.json`));
  return info && info.id === id && (await runnerAnswers(info.socket)) ? info : undefined;
}

/// Every runner there is under `data` (its socket answers), by its record.
export async function existingRunners(data: string): Promise<RunnerInfo[]> {
  const dir = runnersDir(data);
  if (!existsSync(dir)) return [];
  const found: RunnerInfo[] = [];
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
    const info = recordOf(join(dir, f));
    if (info && (await runnerAnswers(info.socket))) found.push(info);
  }
  return found;
}

/// Connections being let go: each one closed on this side and read to its end, so its runner has taken every ack sent on
/// it (a runner reads a connection's messages in order up to its end). One dropped instead could be ended by the next
/// station's attach with its last acks unread, and those lines handled again by it.
const leaving = new Set<Promise<void>>();

export function leave(left: Promise<void>) {
  leaving.add(left);
  void left.finally(() => leaving.delete(left));
}

/// Once every connection let go so far has reached its end.
export async function allLeft() {
  while (leaving.size > 0) await Promise.all(leaving);
}

/// A connection to one runner: what the agent says, line by line, from where this station last acknowledged.
export class RunnerConnection {
  readonly info: RunnerInfo;
  private socket: Socket;
  private carry = "";
  private partial: Record<"out" | "err", Buffer> = { out: Buffer.alloc(0), err: Buffer.alloc(0) };
  /// Where each stream's next line starts, as the runner counts bytes.
  private at: Record<"out" | "err", number> = { out: -1, err: -1 };
  private acked: Record<"out" | "err", number> = { out: 0, err: 0 };
  private queue: Promise<void> = Promise.resolve();
  private left = false;
  readonly exited: Promise<Exit>;
  private exit!: (e: Exit) => void;

  /// `line` is called for each whole line in order, one at a time (a promise is waited for); once it is done, the line
  /// is acknowledged.
  constructor(info: RunnerInfo, line: (stream: "out" | "err", text: string) => void | Promise<void>) {
    this.info = info;
    this.exited = new Promise((resolve) => (this.exit = resolve));
    this.socket = createConnection(info.socket);
    this.socket.on("connect", () => this.send({ op: "attach" }));
    this.socket.on("data", (chunk) => {
      if (this.left) return;
      this.carry += chunk.toString("utf8");
      for (let i = this.carry.indexOf("\n"); i >= 0; i = this.carry.indexOf("\n")) {
        const message = JSON.parse(this.carry.slice(0, i));
        this.carry = this.carry.slice(i + 1);
        if (message.op === "out") this.data(message.stream, message.at, Buffer.from(message.data, "base64"), line);
        else if (message.op === "exit") this.queue = this.queue.then(() => this.exit({ code: message.code, signal: message.signal }));
      }
    });
  }

  private data(stream: "out" | "err", at: number, bytes: Buffer, line: (s: "out" | "err", t: string) => void | Promise<void>) {
    if (this.at[stream] < 0) this.at[stream] = at;
    let buf = Buffer.concat([this.partial[stream], bytes]);
    for (let i = buf.indexOf(10); i >= 0; i = buf.indexOf(10)) {
      const text = buf.subarray(0, i).toString("utf8");
      buf = buf.subarray(i + 1);
      this.at[stream] += i + 1;
      const end = this.at[stream];
      this.queue = this.queue.then(async () => {
        await line(stream, text);
        this.acked[stream] = end;
        this.send({ op: "ack", out: this.acked.out, err: this.acked.err });
      });
    }
    this.partial[stream] = buf;
  }

  private send(message: unknown) {
    if (this.socket.writable) this.socket.write(JSON.stringify(message) + "\n");
  }

  write(text: string) {
    this.send({ op: "write", data: Buffer.from(text).toString("base64") });
  }

  closeStdin() {
    this.send({ op: "close_stdin" });
  }

  signal(signal: "TERM" | "KILL" | "INT", group = true) {
    this.send({ op: "signal", signal, group });
  }

  /// Read to the end: the runner cleans up and goes.
  done() {
    this.send({ op: "done" });
    this.socket.end();
  }

  /// This station lets go (stopping, handing over): the runner keeps the agent for the next one. Its side is closed and
  /// what comes meanwhile is not handled; resolved once the runner, having read to the end, closed it too (or was gone).
  /// A pipe has no closing of one side: it is asked to (`leave`), and closes once it has read up to there.
  detach(): Promise<void> {
    this.left = true;
    if (this.socket.destroyed) return Promise.resolve();
    const closed = new Promise<void>((resolve) => this.socket.once("close", () => resolve()));
    if (platform.runnerSaysLeave) this.send({ op: "leave" });
    this.socket.end();
    return closed;
  }
}
