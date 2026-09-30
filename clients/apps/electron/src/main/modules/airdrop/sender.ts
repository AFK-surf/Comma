import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { lstat } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { z } from "zod";

const peerSchema = z.object({
  id: z.string().min(1).max(256),
  name: z.string().max(1024).optional(),
  model: z.string().max(1024).optional(),
  error: z.string().max(4096).optional(),
});
const eventSchema = z.discriminatedUnion("type", [
  peerSchema.extend({ version: z.literal(1), type: z.literal("peer") }),
  z.object({
    version: z.literal(1),
    type: z.literal("scan_completed"),
    truncated: z.boolean(),
    count: z.number().int().min(0).max(64),
  }),
  z.object({
    version: z.literal(1),
    type: z.literal("send_completed"),
    peerId: z.string(),
  }),
  // Bytes handed to the transport, not receiver acknowledgement.
  z.object({
    version: z.literal(1),
    type: z.literal("transfer_progress"),
    direction: z.literal("send"),
    peerId: z.string(),
    phase: z.enum(["transferring", "processing", "waiting_for_confirmation"]),
    transferredBytes: z.number().int().nonnegative(),
    totalBytes: z.number().int().nonnegative().optional(),
    fraction: z.number().min(0).max(1).optional(),
    estimated: z.boolean().optional(),
  }),
  z.object({
    version: z.literal(1),
    type: z.enum(["progress", "diagnostic", "operation_failed"]),
    message: z.string().max(8192),
  }),
]);
type Peer = z.infer<typeof peerSchema>;
type SessionBoundary = { assertCurrent(): void; signal: AbortSignal };
export const airDropSendInputSchema = z
  .object({
    requestId: z.string().uuid(),
    peerId: z.string().min(1).max(256),
    /** Files the recipient gets together: one request, one upload. */
    paths: z.array(z.string().min(1).max(8192)).min(1).max(50),
  })
  .strict();
export type AirDropSendInput = z.infer<typeof airDropSendInputSchema>;
export interface AirDropOperation {
  operationId: string;
  kind: "find" | "send";
  status: "running" | "succeeded" | "failed" | "cancelled" | "timed_out";
  progress?: string;
  /** The latest byte count of a running send. */
  transfer?: {
    fraction?: number;
    phase: "transferring" | "processing" | "waiting_for_confirmation";
    totalBytes?: number;
    transferredBytes: number;
  };
  error?: string;
  peerId?: string;
  paths?: string[];
  peers?: Peer[];
  truncated?: boolean;
}
interface ActiveOperation {
  value: AirDropOperation;
  boundary: SessionBoundary;
  child?: ChildProcessWithoutNullStreams;
  done: Promise<void>;
  finish(): void;
  stop?: () => void;
  preparing?: boolean;
}
interface AirDropSenderOptions {
  binaryPath?: string | undefined;
  bindSession: () => SessionBoundary;
  platform?: string;
  resolveVfs?: (path: string) => Promise<string>;
}

/**
 * Ephemeral Client API invocations. One outbound operation runs per signed-in
 * app. Scans and sends use the anonymous identity, so the receiving device must
 * accept AirDrop from everyone.
 */
export class AirDropSender {
  readonly #options: AirDropSenderOptions;
  readonly #history = new Map<string, AirDropOperation>();
  #active: ActiveOperation | undefined;
  #peers: Peer[] = [];
  #peersExpireAt = 0;
  #disposed = false;

  constructor(options: AirDropSenderOptions) {
    this.#options = options;
  }

  status() {
    const available =
      (this.#options.platform ?? process.platform) === "darwin" &&
      !!this.#options.binaryPath &&
      existsSync(this.#options.binaryPath);
    return {
      available,
      identity: "anonymous",
      active:
        this.#active && !this.#active.boundary.signal.aborted
          ? structuredClone(this.#active.value)
          : undefined,
      reason: available
        ? undefined
        : "The AirDrop sender helper is unavailable. Build the native AirDrop helpers on macOS.",
    };
  }

  find() {
    const active = this.#begin({
      operationId: randomUUID(),
      kind: "find",
      status: "running",
      peers: [],
    });
    this.#peers = [];
    this.#peersExpireAt = 0;
    this.#spawn(active, [
      "find",
      "--seconds",
      "5",
      "--query-timeout",
      "3",
      "--max-peers",
      "64",
    ]);
    return structuredClone(active.value);
  }

  send(input: AirDropSendInput) {
    input = airDropSendInputSchema.parse(input);
    this.#options.bindSession().assertCurrent();
    const { paths } = input;
    const previous = this.#history.get(input.requestId);
    if (previous) {
      if (
        previous.kind !== "send" ||
        previous.peerId !== input.peerId ||
        previous.paths?.length !== paths.length ||
        previous.paths.some((path, index) => path !== paths[index])
      )
        throw new Error("This requestId belongs to another AirDrop operation.");
      return structuredClone(previous);
    }
    if (
      Date.now() >= this.#peersExpireAt ||
      !this.#peers.some((peer) => peer.id === input.peerId)
    )
      throw new Error(
        "Run AirDrop find again and select a device from the completed scan."
      );
    if (paths.some((path) => !isAbsolute(path) || path.includes("\0")))
      throw new Error("AirDrop requires absolute file paths on this Mac.");
    const active = this.#begin({
      operationId: input.requestId,
      kind: "send",
      status: "running",
      peerId: input.peerId,
      paths,
    });
    active.preparing = true;
    void (async () => {
      try {
        const files: string[] = [];
        let totalSize = 0;
        for (const requested of paths) {
          let path = requested;
          if (requested === "/drive" || requested.startsWith("/drive/")) {
            if (!this.#options.resolveVfs)
              throw new Error("VFS path resolution is unavailable in this client.");
            active.value.progress = "Resolving the local Drive path...";
            path = await this.#options.resolveVfs(requested);
          }
          if (!path) throw new Error("AirDrop has no file source.");
          const stat = await lstat(path);
          active.boundary.assertCurrent();
          if (active.value.status !== "running") {
            active.finish();
            return;
          }
          if (!stat.isFile())
            throw new Error(
              `AirDrop sends regular files. ${requested} is a directory or symbolic link.`
            );
          totalSize += stat.size;
          files.push(path);
        }
        if (totalSize > 1024 * 1024 * 1024)
          throw new Error("AirDrop files must not exceed 1 GiB in total.");
        // The helper checks the batch again, including distinct files.
        this.#spawn(active, [
          "send",
          "--name",
          "Comma",
          "--to",
          input.peerId,
          ...files.flatMap((file) => ["--file", file]),
        ]);
      } catch (error) {
        if (active.value.status === "running") {
          active.value.status = "failed";
          active.value.error =
            error instanceof Error
              ? error.message
              : "Could not prepare the AirDrop files.";
        }
        active.finish();
      }
    })();
    return structuredClone(active.value);
  }

  operation(id: string) {
    this.#options.bindSession().assertCurrent();
    const value = this.#history.get(id);
    if (!value)
      throw new Error("AirDrop operation is no longer available in this session.");
    return structuredClone(value);
  }

  async cancel(id: string) {
    const value = this.operation(id);
    if (this.#active?.value.operationId === id) {
      const active = this.#active;
      this.#cancel(active, "cancelled");
      await active.done;
      return structuredClone(active.value);
    }
    return value;
  }

  reset() {
    const active = this.#active;
    if (active) this.#cancel(active, "cancelled");
    this.#history.clear();
    this.#peers = [];
    this.#peersExpireAt = 0;
    return active?.done ?? Promise.resolve();
  }
  close() {
    this.#disposed = true;
    return this.reset();
  }

  #begin(value: AirDropOperation): ActiveOperation {
    const boundary = this.#options.bindSession();
    boundary.assertCurrent();
    if (this.#disposed || boundary.signal.aborted)
      throw new Error("AirDrop session has ended.");
    const status = this.status();
    if (!status.available) throw new Error(status.reason);
    if (this.#active)
      throw new Error(
        "An AirDrop scan or send is already running. Query or cancel it first."
      );
    let resolve!: () => void;
    let finishing = false;
    const active: ActiveOperation = {
      value,
      boundary,
      done: new Promise<void>((done) => {
        resolve = done;
      }),
      finish: () => {
        if (finishing) return;
        finishing = true;
        clearTimeout(timer);
        boundary.signal.removeEventListener("abort", abort);
        if (this.#active === active) this.#active = undefined;
        resolve();
      },
    };
    const abort = () => this.#cancel(active, "cancelled");
    const timer = setTimeout(
      () => this.#cancel(active, "timed_out"),
      value.kind === "find" ? 25_000 : 5 * 60_000
    );
    boundary.signal.addEventListener("abort", abort, { once: true });
    this.#active = active;
    this.#history.set(value.operationId, value);
    while (this.#history.size > 20)
      this.#history.delete(this.#history.keys().next().value!);
    return active;
  }

  #cancel(active: ActiveOperation, status: "cancelled" | "timed_out") {
    if (active.value.status !== "running") return;
    active.value.status = status;
    active.value.error =
      status === "timed_out"
        ? "AirDrop timed out. Delivery is unconfirmed. Check the receiving device before retrying."
        : "AirDrop was cancelled. Files already received by the other device cannot be recalled.";
    active.stop?.();
    if (!active.child && !active.preparing) active.finish();
  }

  #spawn(active: ActiveOperation, args: string[]) {
    active.boundary.assertCurrent();
    const child = spawn(
      this.#options.binaryPath!,
      [...args, "--json", "--exit-on-stdin-close"],
      { stdio: ["pipe", "pipe", "pipe"], shell: false }
    );
    active.child = child;
    let killTimer: ReturnType<typeof setTimeout> | undefined;
    active.stop = () => {
      if (killTimer) return;
      child.stdin.end();
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 2_000);
    };
    const decoder = new StringDecoder("utf8");
    let buffer = "",
      stderr = "",
      completed = false;
    const fail = (message: string) => {
      if (active.value.status === "running") {
        active.value.status = "failed";
        active.value.error = message;
      }
      active.stop?.();
    };
    child.stdin.on("error", () => undefined);
    child.stderr.on("data", (data: Buffer) => {
      stderr = (stderr + data.toString("utf8")).slice(-4096);
    });
    child.stdout.on("data", (data: Buffer) => {
      if (active.value.status !== "running") return;
      buffer += decoder.write(data);
      if (buffer.length > 64 * 1024) {
        fail("AirDrop helper output exceeds the limit.");
        return;
      }
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        try {
          active.boundary.assertCurrent();
          const event = eventSchema.parse(JSON.parse(line));
          if (event.type === "peer" && active.value.kind === "find") {
            const peers = active.value.peers!;
            if (peers.length >= 64 || peers.some((peer) => peer.id === event.id))
              throw new Error("Invalid peer list.");
            peers.push(peerSchema.parse(event));
          } else if (event.type === "scan_completed" && active.value.kind === "find") {
            if (event.count !== active.value.peers!.length)
              throw new Error("Incomplete peer list.");
            active.value.truncated = event.truncated;
            completed = true;
          } else if (
            event.type === "send_completed" &&
            active.value.kind === "send" &&
            event.peerId === active.value.peerId
          ) {
            completed = true;
          } else if (
            event.type === "transfer_progress" &&
            active.value.kind === "send" &&
            event.peerId === active.value.peerId
          ) {
            active.value.transfer = {
              phase: event.phase,
              transferredBytes: event.transferredBytes,
              ...(event.totalBytes === undefined
                ? {}
                : { totalBytes: event.totalBytes }),
              ...(event.fraction === undefined ? {} : { fraction: event.fraction }),
            };
          } else if (event.type === "operation_failed") {
            fail(event.message);
          } else if (event.type === "progress" || event.type === "diagnostic") {
            active.value.progress = event.message;
          } else {
            throw new Error("Unexpected AirDrop event.");
          }
        } catch {
          fail("Invalid or stale AirDrop helper event. Rebuild the native helpers.");
          return;
        }
      }
    });
    child.once("error", (error) => fail(error.message));
    child.once("close", (code) => {
      clearTimeout(killTimer);
      if (active.value.status === "running") {
        try {
          active.boundary.assertCurrent();
          if (code !== 0 || !completed || buffer.length)
            throw new Error(
              stderr.trim() ||
                "AirDrop ended without confirmation. Delivery is unconfirmed."
            );
          active.value.status = "succeeded";
          if (active.value.kind === "find") {
            this.#peers = structuredClone(active.value.peers!);
            this.#peersExpireAt = Date.now() + 2 * 60_000;
          }
        } catch (error) {
          active.value.status = "failed";
          active.value.error =
            error instanceof Error ? error.message : "AirDrop failed.";
        }
      }
      active.finish();
    });
  }
}
