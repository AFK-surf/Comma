import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer } from "node:net";
import { realMainClock, type MainClock } from "../../clock";

/**
 * Main's end of the Blender bridge: a loopback server that the bridge script in
 * each interactive Blender connects to (comma_bridge.py). A connection counts
 * only after its hello carries this run's token. Messages are JSON, each after
 * its 4-byte big-endian length.
 */

export const BRIDGE_PROTOCOL = 1;
const MAX_FRAME = 64 * 1024 * 1024;
/** A hello must arrive this soon after a connection opens. */
const HELLO_TIMEOUT_MS = 5_000;

export interface BlenderInstanceInfo {
  id: string;
  pid: number;
  version: string;
  binary: string;
  platform: string;
}

export class BlenderRequestError extends Error {}

/** One connection's end in Main: a `net.Socket` in the app. */
export interface BridgeSocket {
  write(data: Buffer): unknown;
  destroy(): unknown;
  on(event: "data", listener: (chunk: Buffer) => void): unknown;
  on(event: "close" | "error", listener: () => void): unknown;
}

/** Listens on a loopback port; each connection reaches `accept`. */
export type ListenBridge = (
  accept: (socket: BridgeSocket) => void
) => Promise<{ port: number; close(): Promise<void> }>;

export const listenLoopback: ListenBridge = async (accept) => {
  const server = createServer((socket) => accept(socket));
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("no bridge port");
  return {
    port: address.port,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
};

interface Pending {
  resolve(result: unknown): void;
  reject(error: Error): void;
  cancelTimer: () => void;
}

export class BlenderConnection {
  readonly #socket: BridgeSocket;
  readonly #clock: MainClock;
  readonly #pending = new Map<string, Pending>();
  #closed = false;

  constructor(
    readonly info: BlenderInstanceInfo,
    socket: BridgeSocket,
    clock: MainClock
  ) {
    this.#socket = socket;
    this.#clock = clock;
  }

  get closed() {
    return this.#closed;
  }

  /** Runs one operation on Blender's main thread; rejects after `timeoutMs`. */
  request(
    op: string,
    args: Record<string, unknown>,
    timeoutMs: number
  ): Promise<unknown> {
    if (this.#closed)
      return Promise.reject(
        new BlenderRequestError("This Blender is no longer connected.")
      );
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const cancelTimer = this.#clock.setTimer(timeoutMs, () => {
        this.#pending.delete(id);
        reject(
          new BlenderRequestError(
            `Blender did not answer in ${Math.round(timeoutMs / 1000)} seconds; it may be busy. The operation may still finish.`
          )
        );
      });
      this.#pending.set(id, { resolve, reject, cancelTimer });
      this.#socket.write(frame({ type: "request", id, op, args }));
    });
  }

  /** @internal */
  receive(message: Record<string, unknown>) {
    if (message.type !== "reply" || typeof message.id !== "string") return;
    const pending = this.#pending.get(message.id);
    if (!pending) return;
    this.#pending.delete(message.id);
    pending.cancelTimer();
    if (message.ok === true) pending.resolve(message.result);
    else
      pending.reject(
        new BlenderRequestError(String(message.error ?? "Blender failed."))
      );
  }

  /** @internal */
  close() {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) {
      pending.cancelTimer();
      pending.reject(new BlenderRequestError("This Blender disconnected."));
    }
    this.#pending.clear();
    this.#socket.destroy();
  }
}

export class BlenderBridgeServer {
  readonly token = randomBytes(32).toString("hex");
  readonly #clock: MainClock;
  readonly #onChange: () => void;
  readonly #connections = new Map<string, BlenderConnection>();
  readonly #listen: ListenBridge;
  #server: { port: number; close(): Promise<void> } | undefined;

  constructor(
    options: { clock?: MainClock; onChange?: () => void; listen?: ListenBridge } = {}
  ) {
    this.#clock = options.clock ?? realMainClock;
    this.#onChange = options.onChange ?? (() => undefined);
    this.#listen = options.listen ?? listenLoopback;
  }

  get port() {
    return this.#server?.port;
  }

  /** The connected Blenders, oldest first. */
  connections(): BlenderConnection[] {
    return [...this.#connections.values()];
  }

  connection(id: string): BlenderConnection | undefined {
    return this.#connections.get(id);
  }

  async start(): Promise<number> {
    this.#server ??= await this.#listen((socket) => this.#accept(socket));
    return this.#server.port;
  }

  async stop() {
    for (const connection of this.#connections.values()) connection.close();
    this.#connections.clear();
    const server = this.#server;
    this.#server = undefined;
    await server?.close();
  }

  #accept(socket: BridgeSocket) {
    let buffer = Buffer.alloc(0);
    let connection: BlenderConnection | undefined;
    const cancelHello = this.#clock.setTimer(HELLO_TIMEOUT_MS, () => {
      if (!connection) socket.destroy();
    });
    socket.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const size = buffer.readUInt32BE(0);
        if (size > MAX_FRAME) return socket.destroy();
        if (buffer.length < 4 + size) break;
        let message: unknown;
        try {
          message = JSON.parse(buffer.subarray(4, 4 + size).toString("utf8"));
        } catch {
          return socket.destroy();
        }
        buffer = buffer.subarray(4 + size);
        if (!isRecord(message)) return socket.destroy();
        if (connection) {
          connection.receive(message);
          continue;
        }
        const info = this.#hello(message);
        if (!info) return socket.destroy();
        cancelHello();
        connection = new BlenderConnection(info, socket, this.#clock);
        this.#connections.get(info.id)?.close();
        this.#connections.set(info.id, connection);
        this.#onChange();
      }
    });
    const drop = () => {
      cancelHello();
      if (!connection) return;
      connection.close();
      if (this.#connections.get(connection.info.id) === connection) {
        this.#connections.delete(connection.info.id);
        this.#onChange();
      }
    };
    socket.on("close", drop);
    socket.on("error", drop);
  }

  #hello(message: Record<string, unknown>): BlenderInstanceInfo | undefined {
    if (message.type !== "hello" || message.protocol !== BRIDGE_PROTOCOL)
      return undefined;
    if (typeof message.token !== "string" || !sameToken(message.token, this.token))
      return undefined;
    const instance = message.instance;
    if (
      !isRecord(instance) ||
      typeof instance.id !== "string" ||
      !/^[0-9a-f]{32}$/.test(instance.id)
    )
      return undefined;
    return {
      id: instance.id,
      pid: typeof instance.pid === "number" ? instance.pid : 0,
      version:
        typeof instance.version === "string" ? instance.version.slice(0, 64) : "",
      binary: typeof instance.binary === "string" ? instance.binary.slice(0, 4096) : "",
      platform:
        typeof instance.platform === "string" ? instance.platform.slice(0, 32) : "",
    };
  }
}

export function frame(message: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

function sameToken(given: string, expected: string) {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
