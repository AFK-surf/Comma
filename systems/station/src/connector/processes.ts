// Long-running processes the agent manages by name (process_start/list/write/tail/stop). Output is kept in a bounded
// ring per stream; tails can wait for new output. Writes to a process's stdin are serialized and each is bounded by a
// deadline, so an interrupted or stuck write never holds stdin for the next one.
import type { ChildProcess } from "node:child_process";
import { endCommand, startCommand } from "../ops/processes.ts";
import { Deferred, Duration, Effect, Exit, Semaphore } from "effect";
import { boolParam, intParam, stringParam, stringSliceParam } from "./message.ts";

export const MAX_PROCESS_BYTES = 2 * 1024 * 1024;
export const PROCESS_WRITE_TIMEOUT = Duration.seconds(30);
export const PROCESS_STOP_GRACE = Duration.seconds(2);

/** A process's stdin as the connector writes it. */
export type ProcessStdin = {
  write(data: string): Effect.Effect<number, Error>;
  close: Effect.Effect<void>;
};

// Windows' own besides: without SystemRoot and ComSpec many programs do not start, and PATHEXT is how a bare name is
// found. Names are matched whatever their case, as Windows has them (`Path`), and kept as the host spells them.
const PROCESS_START_BASE_ENV = new Set([
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "LC_CTYPE", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
  "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "USERPROFILE", "USERNAME", "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "PROGRAMFILES", "HOMEDRIVE", "HOMEPATH",
]);

/** A process_start environment: a short list of host variables, then the caller's. */
export function processStartEnv(host: Record<string, string | undefined>, extra: unknown): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(host)) if (value !== undefined && PROCESS_START_BASE_ENV.has(key.toUpperCase())) env[key] = value;
  if (extra && typeof extra === "object" && !Array.isArray(extra)) for (const [k, v] of Object.entries(extra)) env[k] = String(v);
  return env;
}

/** An exec environment: the whole host environment, then the caller's. */
export function execEnv(host: Record<string, string | undefined>, extra: unknown): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(host)) if (v !== undefined) env[k] = v;
  if (extra && typeof extra === "object" && !Array.isArray(extra)) for (const [k, v] of Object.entries(extra)) env[k] = String(v);
  return env;
}

class ProcessOutput {
  private data = Buffer.alloc(0);
  private baseOffset = 0;
  private nextOffset = 0;
  private waiters: Array<() => void> = [];

  append(chunk: Buffer) {
    this.data = Buffer.concat([this.data, chunk]);
    this.nextOffset += chunk.length;
    if (this.data.length > MAX_PROCESS_BYTES) {
      const drop = this.data.length - MAX_PROCESS_BYTES;
      this.data = Buffer.from(this.data.subarray(drop));
      this.baseOffset += drop;
    }
    for (const wake of this.waiters.splice(0)) wake();
  }

  read(from: number, maxBytes: number, tailBytes: number) {
    if (tailBytes > 0) from = this.nextOffset - tailBytes;
    from = Math.min(Math.max(from, this.baseOffset), this.nextOffset);
    const start = from - this.baseOffset;
    let end = this.data.length;
    if (maxBytes > 0 && start + maxBytes < end) end = start + maxBytes;
    return { data: this.data.subarray(start, end).toString(), base: from, next: this.baseOffset + end };
  }

  /** Resolves on the next append. */
  get changed(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      this.waiters.push(() => resume(Effect.void));
    });
  }
}

export class ManagedProcess {
  status: "starting" | "running" | "exited" | "failed" = "starting";
  exitCode: number | undefined;
  exitError = "";
  readonly stdout = new ProcessOutput();
  readonly stderr = new ProcessOutput();
  readonly exited = Deferred.makeUnsafe<void>();
  readonly stdinSlot = Semaphore.makeUnsafe(1);
  stdinBusy = false;

  readonly name: string;
  readonly stdin: ProcessStdin;
  readonly startedAt: number;
  readonly child?: ChildProcess;

  constructor(name: string, stdin: ProcessStdin, startedAt: number, child?: ChildProcess) {
    this.name = name;
    this.stdin = stdin;
    this.startedAt = startedAt;
    this.child = child;
  }

  isRunning() {
    return this.status === "running" || this.status === "starting";
  }

  summary(): Record<string, unknown> {
    const out: Record<string, unknown> = { process_name: this.name, status: this.status, started_at: this.startedAt };
    if (this.child?.pid) out.pid = this.child.pid;
    if (this.exitCode !== undefined) out.exit_code = this.exitCode;
    if (this.exitError) out.error = this.exitError;
    return out;
  }

  finish(code: number | null, signal: NodeJS.Signals | null) {
    if (!this.isRunning()) return;
    this.exitCode = code ?? -1;
    if (code === 0) this.status = "exited";
    else {
      this.status = "failed";
      this.exitError = signal ? `signal: ${signal === "SIGKILL" ? "killed" : signal === "SIGINT" ? "interrupt" : signal}` : `exit status ${code}`;
    }
    Deferred.doneUnsafe(this.exited, Exit.void);
  }
}

/** Starts `command` in its own process group with piped stdio; resolves once the process is spawned. */
export function spawnManaged(name: string, command: string, args: string[], cwd: string, env: Record<string, string>, nowMs: number): Effect.Effect<ManagedProcess, Error> {
  return Effect.callback<ManagedProcess, Error>((resume) => {
    const child = startCommand(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
    const stdin: ProcessStdin = {
      write: (data) =>
        Effect.callback<number, Error>((done) => {
          child.stdin!.write(data, (error) => done(error ? Effect.fail(error) : Effect.succeed(Buffer.byteLength(data))));
        }),
      close: Effect.sync(() => child.stdin?.end()),
    };
    child.stdin!.on("error", () => {});
    const proc = new ManagedProcess(name, stdin, nowMs, child);
    child.stdout!.on("data", (chunk: Buffer) => proc.stdout.append(chunk));
    child.stderr!.on("data", (chunk: Buffer) => proc.stderr.append(chunk));
    child.once("error", (error) => {
      if (proc.status === "starting") resume(Effect.fail(error));
    });
    child.once("spawn", () => {
      proc.status = "running";
      resume(Effect.succeed(proc));
    });
    child.once("close", (code, signal) => proc.finish(code, signal));
  });
}

export function makeProcessTable() {
  const processes = new Map<string, ManagedProcess>();

  const lookup = (name: string) =>
    Effect.suspend(() => {
      if (!name) return Effect.fail(new Error("'process_name' is required"));
      const proc = processes.get(name);
      return proc ? Effect.succeed(proc) : Effect.fail(new Error(`process "${name}" not found`));
    });

  return {
    processes,
    lookup,
    register(proc: ManagedProcess) {
      processes.set(proc.name, proc);
    },
    list: (): Record<string, unknown> => ({ processes: [...processes.values()].sort((a, b) => (a.name < b.name ? -1 : 1)).map((p) => p.summary()) }),
    /** Writes to stdin, one write per process at a time, bounded by the process write deadline. */
    write: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const proc = yield* lookup(stringParam(params, "process_name"));
        if (!proc.isRunning()) return yield* Effect.fail(new Error(`process "${proc.name}" is not running`));
        let data = stringParam(params, "data");
        if (boolParam(params, "append_newline")) data += "\n";
        if (data === "") return { bytes_written: 0 };
        const written = yield* Semaphore.withPermits(
          proc.stdinSlot,
          1,
        )(
          Effect.acquireUseRelease(
            Effect.sync(() => (proc.stdinBusy = true)),
            () => proc.stdin.write(data).pipe(Effect.timeoutOption(PROCESS_WRITE_TIMEOUT)),
            () => Effect.sync(() => (proc.stdinBusy = false)),
          ),
        );
        if (written._tag === "None") return yield* Effect.fail(new Error("process stdin write timed out"));
        return { bytes_written: written.value };
      }),
    tail: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const proc = yield* lookup(stringParam(params, "process_name"));
        const streamName = stringParam(params, "stream") || "stdout";
        if (streamName !== "stdout" && streamName !== "stderr") return yield* Effect.fail(new Error("'stream' must be stdout or stderr"));
        const output = streamName === "stdout" ? proc.stdout : proc.stderr;
        const from = intParam(params, "from_offset", 0);
        let maxBytes = intParam(params, "max_bytes", 64 * 1024);
        if (maxBytes <= 0) maxBytes = 64 * 1024;
        const tailBytes = intParam(params, "tail_bytes", 0);
        const waitSeconds = intParam(params, "wait_seconds", 0);
        let read = output.read(from, maxBytes, tailBytes);
        if (read.data === "" && proc.isRunning() && waitSeconds > 0) {
          const changed = output.changed;
          yield* Effect.raceFirst(Effect.raceFirst(changed, Deferred.await(proc.exited)), Effect.sleep(Duration.seconds(waitSeconds)));
          read = output.read(from, maxBytes, tailBytes);
        }
        return { ...proc.summary(), stream: streamName, offset: read.base, next_offset: read.next, data: read.data, truncated: read.base > from && tailBytes <= 0 };
      }),
    stop: (params: Record<string, unknown>) =>
      Effect.gen(function* () {
        const proc = yield* lookup(stringParam(params, "process_name"));
        if (proc.isRunning() && proc.child?.pid) {
          signalGroup(proc.child, "SIGINT");
          const exited = yield* Deferred.await(proc.exited).pipe(Effect.timeoutOption(PROCESS_STOP_GRACE));
          if (exited._tag === "None") {
            signalGroup(proc.child, "SIGKILL");
            yield* Deferred.await(proc.exited);
          }
        }
        return proc.summary();
      }),
    /** Kills every running process (scope narrowing and shutdown). */
    killAll: () =>
      Effect.forEach(
      [...processes.values()],
      (proc) =>
        Effect.suspend(() => {
          if (!proc.isRunning() || !proc.child?.pid) return Effect.void;
          signalGroup(proc.child, "SIGKILL");
          return Deferred.await(proc.exited);
        }),
      { discard: true },
    ),
  };
}

export function signalGroup(child: ChildProcess, signal: NodeJS.Signals) {
  endCommand(child, signal);
}
