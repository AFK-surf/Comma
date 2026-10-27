import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { StringDecoder } from "node:string_decoder";
import { realMainClock, type MainClock } from "../../clock";

/**
 * The MCP client side of MacAppsHost (native/macos/MacAppsHost): Main starts the
 * server on first use and is its only client, over newline-delimited JSON-RPC on
 * stdin and stdout. The server implements MCP with the official Swift SDK; Main
 * only sends whole messages and reads whole replies, so it needs no MCP library.
 */

const PROTOCOL_VERSION = "2025-06-18";
/** The server gives each tool 20 seconds; this covers starting it and the reply. */
const REQUEST_TIMEOUT_MS = 25_000;
/** A server that exits is started again on the next request, at most this often. */
const RESTART_INTERVAL_MS = 1_000;

export class McpRemoteError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown
  ) {
    super(message);
  }
}

export interface InitializeResult {
  protocolVersion: string;
  serverInfo: { name: string; version: string; title?: string };
  capabilities: Record<string, unknown>;
}

type SpawnServer = (binaryPath: string) => ChildProcessWithoutNullStreams;

interface Pending {
  resolve(result: unknown): void;
  reject(error: Error): void;
  cancelTimer: () => void;
}

export class MacAppsEngine {
  readonly #binaryPath: string;
  readonly #spawn: SpawnServer;
  readonly #log: (message: string) => void;
  readonly #requestTimeoutMs: number;
  readonly #clock: MainClock;
  #child: ChildProcessWithoutNullStreams | undefined;
  #initialized: Promise<InitializeResult> | undefined;
  #pending = new Map<number, Pending>();
  #nextId = 1;
  #lastStart = 0;

  constructor(options: {
    binaryPath: string;
    spawn?: SpawnServer;
    log?: (message: string) => void;
    requestTimeoutMs?: number;
    clock?: MainClock;
  }) {
    this.#binaryPath = options.binaryPath;
    this.#spawn =
      options.spawn ??
      ((path) => spawn(path, ["serve"], { stdio: ["pipe", "pipe", "pipe"] }));
    this.#log = options.log ?? (() => undefined);
    this.#requestTimeoutMs = options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
    this.#clock = options.clock ?? realMainClock;
  }

  /** The server's `initialize` answer, starting the server when it is not running. */
  initialize(): Promise<InitializeResult> {
    this.#initialized ??= this.#start().catch((error: unknown) => {
      this.#initialized = undefined;
      throw error;
    });
    return this.#initialized;
  }

  async request(method: string, params: unknown): Promise<unknown> {
    await this.initialize();
    return this.#send(method, params);
  }

  /** Ends the server; the next request starts it again. */
  async stop() {
    const child = this.#child;
    this.#child = undefined;
    this.#initialized = undefined;
    this.#rejectAll(new Error("The Mac apps server is stopped."));
    // Closing stdin ends the server; it exits when its input ends.
    child?.stdin.end();
  }

  /**
   * Ends the server when it answers no request, so the next request starts a
   * new one; false when a request is still running and the server is kept.
   */
  async restartWhenIdle(): Promise<boolean> {
    if (this.#pending.size > 0) return false;
    await this.stop();
    return true;
  }

  async #start(): Promise<InitializeResult> {
    const wait = this.#lastStart + RESTART_INTERVAL_MS - this.#clock.now();
    if (wait > 0)
      await new Promise<void>((resolve) => this.#clock.setTimer(wait, resolve));
    this.#lastStart = this.#clock.now();

    const child = this.#spawn(this.#binaryPath);
    this.#child = child;
    const decoder = new StringDecoder("utf8");
    let buffered = "";
    child.stdout.on("data", (chunk: Buffer) => {
      buffered += decoder.write(chunk);
      let newline: number;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline).trim();
        buffered = buffered.slice(newline + 1);
        if (line) this.#receive(line);
      }
    });
    child.stderr.on("data", (chunk: Buffer) => {
      this.#log(`[mac-apps] ${chunk.toString("utf8").trimEnd()}`);
    });
    const ended = (reason: string) => {
      if (this.#child !== child) return;
      this.#child = undefined;
      this.#initialized = undefined;
      this.#rejectAll(new Error(`The Mac apps server ${reason}.`));
    };
    child.on("error", (error) => ended(`could not start: ${error.message}`));
    child.on("exit", (code, signal) => ended(`stopped (${signal ?? code})`));
    child.stdin.on("error", () => ended("closed its input"));

    const result = (await this.#send("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "comma-main", version: "1" },
    })) as InitializeResult;
    this.#write({ jsonrpc: "2.0", method: "notifications/initialized" });
    return result;
  }

  #send(method: string, params: unknown): Promise<unknown> {
    const child = this.#child;
    if (!child) return Promise.reject(new Error("The Mac apps server is not running."));
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const cancelTimer = this.#clock.setTimer(this.#requestTimeoutMs, () => {
        this.#pending.delete(id);
        reject(new Error(`The Mac apps server did not answer ${method} in time.`));
      });
      this.#pending.set(id, { resolve, reject, cancelTimer });
      this.#write({ jsonrpc: "2.0", id, method, params });
    });
  }

  #write(message: unknown) {
    this.#child?.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #receive(line: string) {
    let message: {
      id?: unknown;
      result?: unknown;
      error?: { code: number; message: string; data?: unknown };
    };
    try {
      message = JSON.parse(line);
    } catch {
      this.#log("[mac-apps] the server wrote a line that is not JSON");
      return;
    }
    // The server sends no requests or notifications Main needs to answer.
    if (typeof message.id !== "number") return;
    const pending = this.#pending.get(message.id);
    if (!pending) return;
    this.#pending.delete(message.id);
    pending.cancelTimer();
    if (message.error) {
      pending.reject(
        new McpRemoteError(
          message.error.code,
          message.error.message,
          message.error.data
        )
      );
    } else {
      pending.resolve(message.result);
    }
  }

  #rejectAll(error: Error) {
    for (const pending of this.#pending.values()) {
      pending.cancelTimer();
      pending.reject(error);
    }
    this.#pending.clear();
  }
}
