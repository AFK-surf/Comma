// Native child processes of runtimes and probes: each runs in its own process group (killing the group also ends a
// wrapper's children), with bounded output, a deadline on the connector's clock, and a cleanup that never waits on a
// process that does not exit.
import type { ChildProcess } from "node:child_process";
import { Deferred, Duration, Effect, Exit } from "effect";
import { endCommand, startCommand } from "../ops/processes.ts";

export type ChildExit = { code: number | null; signal: NodeJS.Signals | null; error: Error | null };

/** Starts `command` in a new process group; spawn errors surface through `exited`. */
export function spawnGroup(command: string, args: string[], options: { cwd?: string; env: Record<string, string>; stdin?: "pipe" | "ignore"; stdout?: "pipe" | "ignore"; stderr?: "pipe" | "ignore" }) {
  const child = startCommand(command, args, { cwd: options.cwd, env: options.env, stdio: [options.stdin ?? "ignore", options.stdout ?? "pipe", options.stderr ?? "pipe"] });
  const exit = Deferred.makeUnsafe<ChildExit>();
  let spawnError: Error | null = null;
  child.once("error", (error) => {
    spawnError = error;
    // A failed spawn emits no close when no stdio was opened.
    if (child.pid === undefined) Deferred.doneUnsafe(exit, Exit.succeed({ code: null, signal: null, error }));
  });
  child.once("close", (code, signal) => Deferred.doneUnsafe(exit, Exit.succeed({ code, signal, error: spawnError })));
  child.stdin?.on("error", () => {});
  return { child, exited: Deferred.await(exit), exitDeferred: exit };
}

export function killGroup(child: ChildProcess | null | undefined) {
  if (!child || child.pid === undefined) return;
  endCommand(child, "SIGKILL");
}

/** Collects at most `limit` bytes; `overflow` reports a stream that went past it. */
export class BoundedOutput {
  private chunks: Buffer[] = [];
  size = 0;
  overflow = false;
  readonly limit: number;
  constructor(limit: number) {
    this.limit = limit;
  }
  push(chunk: Buffer) {
    const room = this.limit - this.size;
    if (chunk.length > room) {
      this.overflow = true;
      if (room > 0) this.chunks.push(chunk.subarray(0, room));
      this.size = this.limit;
      return;
    }
    this.chunks.push(chunk);
    this.size += chunk.length;
  }
  bytes() {
    return Buffer.concat(this.chunks);
  }
  text() {
    return this.bytes().toString("utf8");
  }
}

/** A diagnostic stream (stderr): its first 32 KiB, classified for safe failure categories. */
export class DiagnosticBuffer {
  private readonly output = new BoundedOutput(32 * 1024);
  write(chunk: Buffer | string) {
    if (!this.output.overflow) this.output.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  text() {
    return this.output.text();
  }
  category(): string {
    const text = this.text().toLowerCase();
    if (text.includes("usage limit") || text.includes("quota") || text.includes("credit balance")) return "quota_exhausted";
    if (text.includes("rate limit") || text.includes("too many requests")) return "rate_limited";
    if (["not logged in", "authentication", "please login", "invalid api key", "unauthorized", "invalid token"].some((s) => text.includes(s))) return "authentication_required";
    if (["configuration", "invalid model", "model not found", "model unavailable"].some((s) => text.includes(s))) return "configuration_invalid";
    if (["stream-json", "unknown option", "unexpected argument"].some((s) => text.includes(s))) return "unsupported_stream_json";
    return "runtime_failed";
  }
  /** Only an unexplained failure or a missing stream-json mode may fall back to another harness. */
  permitsStartupRetry() {
    const category = this.category();
    return category === "runtime_failed" || category === "unsupported_stream_json";
  }
}

export type BoundedRun = { exit: ChildExit; stdout: Buffer; stdoutOverflow: boolean; stderr: DiagnosticBuffer; timedOut: boolean };

/**
 * Runs a command to completion with its stdout bounded (an overflow kills the group at once) and a deadline. The
 * group is killed when it finishes, so no child of an exited wrapper outlives the run.
 */
export function runBounded(command: string, args: string[], options: { cwd?: string; env: Record<string, string>; timeout: Duration.Input; stdoutLimit: number; combine?: boolean }): Effect.Effect<BoundedRun> {
  return Effect.suspend(() => {
    const { child, exited } = spawnGroup(command, args, { cwd: options.cwd, env: options.env });
    const stdout = new BoundedOutput(options.stdoutLimit);
    const stderr = new DiagnosticBuffer();
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout.push(chunk);
      if (stdout.overflow) killGroup(child);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      if (options.combine) {
        stdout.push(chunk);
        if (stdout.overflow) killGroup(child);
      }
      stderr.write(chunk);
    });
    return exited.pipe(
      Effect.timeoutOption(options.timeout),
      Effect.map((outcome) => ({
        exit: outcome._tag === "Some" ? outcome.value : { code: null, signal: null, error: null },
        stdout: stdout.bytes(),
        stdoutOverflow: stdout.overflow,
        stderr,
        timedOut: outcome._tag === "None",
      })),
      Effect.ensuring(Effect.sync(() => killGroup(child))),
      Effect.onInterrupt(() => Effect.sync(() => killGroup(child))),
    );
  });
}

/** Waits for `exited` at most `timeout`; true when it exited. */
export const waitExit = (exited: Effect.Effect<unknown>, timeout: Duration.Input): Effect.Effect<boolean> =>
  exited.pipe(
    Effect.timeoutOption(timeout),
    Effect.map((o) => o._tag === "Some"),
  );

export const shellQuote = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;
