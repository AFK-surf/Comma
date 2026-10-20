/**
 * An in-process AirDrop helper. The sender and the reception service drive it
 * through the same pipes, signals and exit events as the native binary, without
 * starting a process. A script plays the helper's side of the JSON protocol.
 */
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { StringDecoder } from "node:string_decoder";
import type { SpawnAirDropHelper } from "../main/modules/airdrop/helper-process";

export interface AirDropHelperRun {
  readonly args: readonly string[];
  /** The value after a flag, such as `--directory`. */
  arg(flag: string): string | undefined;
  /** Writes one protocol event line, as the native helpers do. */
  emit(event: Record<string, unknown>): void;
  stdout(text: string): void;
  stderr(text: string): void;
  /** Calls back once per line the parent writes to stdin. */
  onLine(listener: (line: string) => void): void;
  /** Calls back when the parent closes stdin. */
  onStdinEnd(listener: () => void): void;
  exit(code?: number): void;
}
export type AirDropHelperScript = (run: AirDropHelperRun) => void;

/** Output reaches the parent's listeners as soon as the script writes it. */
class Output extends EventEmitter {
  write(text: string) {
    this.emit("data", Buffer.from(text, "utf8"));
  }
}

/** The parent's writes reach the script on a later turn, as through a pipe. */
class Input extends EventEmitter {
  destroyed = false;
  readonly #lines: ((line: string) => void)[] = [];
  readonly #ends: (() => void)[] = [];
  readonly #decoder = new StringDecoder("utf8");
  #buffer = "";
  #ended = false;
  write(chunk: string | Buffer) {
    if (this.#ended) return false;
    this.#buffer += typeof chunk === "string" ? chunk : this.#decoder.write(chunk);
    let newline: number;
    while ((newline = this.#buffer.indexOf("\n")) >= 0) {
      const line = this.#buffer.slice(0, newline);
      this.#buffer = this.#buffer.slice(newline + 1);
      setImmediate(() => {
        if (!this.destroyed) for (const listener of this.#lines) listener(line);
      });
    }
    return true;
  }
  end() {
    if (this.#ended) return this;
    this.#ended = true;
    setImmediate(() => {
      if (!this.destroyed) for (const listener of this.#ends) listener();
    });
    return this;
  }
  onLine(listener: (line: string) => void) {
    this.#lines.push(listener);
  }
  onEnd(listener: () => void) {
    this.#ends.push(listener);
  }
}

export class FakeAirDropHelperProcess extends EventEmitter {
  readonly stdin = new Input();
  readonly stdout = new Output();
  readonly stderr = new Output();
  readonly pid: number;
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  /** Signals the parent sent, in order. */
  readonly signals: NodeJS.Signals[] = [];
  /** Resolves after the parent's `close` listeners ran. */
  readonly closed: Promise<void>;
  /** Resolves after the script's first turn ran. */
  readonly started: Promise<void>;
  #exited = false;
  #resolveClosed!: () => void;

  constructor(
    readonly command: string,
    readonly args: readonly string[],
    script: AirDropHelperScript,
    pid: number
  ) {
    super();
    this.pid = pid;
    this.closed = new Promise((resolve) => {
      this.#resolveClosed = resolve;
    });
    const run: AirDropHelperRun = {
      args,
      arg: (flag) => {
        const index = args.indexOf(flag);
        return index < 0 ? undefined : args[index + 1];
      },
      emit: (event) => run.stdout(JSON.stringify({ version: 1, ...event }) + "\n"),
      stdout: (text) => {
        if (!this.#exited) this.stdout.write(text);
      },
      stderr: (text) => {
        if (!this.#exited) this.stderr.write(text);
      },
      onLine: (listener) => this.stdin.onLine(listener),
      onStdinEnd: (listener) => this.stdin.onEnd(listener),
      exit: (code = 0) => this.#exit(code, null),
    };
    // The parent attaches its listeners before the helper runs.
    this.started = new Promise((resolve) =>
      setImmediate(() => {
        try {
          script(run);
        } catch (error) {
          run.stderr(error instanceof Error ? error.message : String(error));
          run.exit(1);
        }
        resolve();
      })
    );
  }

  /** A signal ends the helper on a later turn, as the default handler does. */
  kill(signal: NodeJS.Signals = "SIGTERM") {
    if (this.#exited) return false;
    this.signals.push(signal);
    setImmediate(() => this.#exit(null, signal));
    return true;
  }

  #exit(code: number | null, signal: NodeJS.Signals | null) {
    if (this.#exited) return;
    this.#exited = true;
    this.exitCode = code;
    this.signalCode = signal;
    this.stdin.destroyed = true;
    this.emit("exit", code, signal);
    this.emit("close", code, signal);
    this.#resolveClosed();
  }
}

/** Every spawn runs `script` in a new fake process. */
export function fakeAirDropHelper(script: AirDropHelperScript) {
  const processes: FakeAirDropHelperProcess[] = [];
  const waiting: ((child: FakeAirDropHelperProcess) => void)[] = [];
  const spawn: SpawnAirDropHelper = (command, args) => {
    const child = new FakeAirDropHelperProcess(
      command,
      args,
      script,
      10_000 + processes.length
    );
    processes.push(child);
    waiting.shift()?.(child);
    return child as unknown as ChildProcessWithoutNullStreams;
  };
  return {
    spawn,
    processes,
    /** The process of the next spawn. Ask before the action that spawns it. */
    nextSpawn() {
      return new Promise<FakeAirDropHelperProcess>((resolve) => waiting.push(resolve));
    },
  };
}
