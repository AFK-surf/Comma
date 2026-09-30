import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { lstat, mkdir, realpath } from "node:fs/promises";
import { basename, isAbsolute, join, relative } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { z } from "zod";

const offerSchema = z.object({
  version: z.literal(1),
  type: z.literal("approval_requested"),
  requestId: z.string().uuid(),
  senderName: z.string().optional(),
  files: z
    .array(
      z.object({
        name: z.string(),
        isDirectory: z.boolean(),
        size: z.number().nonnegative().optional(),
      })
    )
    .max(50),
  linkCount: z.number().int().min(0).max(50),
});
const eventSchema = z.discriminatedUnion("type", [
  z.object({
    version: z.literal(1),
    type: z.literal("listening"),
    port: z.number().int().min(1).max(65535),
  }),
  offerSchema,
  z.object({
    version: z.literal(1),
    type: z.literal("transfer_saved"),
    requestId: z.string().uuid(),
    paths: z.array(z.string()).max(50),
    complete: z.boolean(),
  }),
  z.object({
    version: z.literal(1),
    type: z.literal("transfer_failed"),
    requestId: z.string().uuid(),
    message: z.string(),
  }),
  // About once per second while an accepted upload runs; not a completion.
  z.object({
    version: z.literal(1),
    type: z.literal("transfer_progress"),
    requestId: z.string().uuid(),
    direction: z.literal("receive"),
    phase: z.enum(["transferring", "processing", "waiting_for_confirmation"]),
    transferredBytes: z.number().int().nonnegative(),
    totalBytes: z.number().int().nonnegative().optional(),
    fraction: z.number().min(0).max(1).optional(),
    estimated: z.boolean().optional(),
  }),
  z.object({
    version: z.literal(1),
    type: z.literal("transfer_warning"),
    requestId: z.string().uuid(),
    message: z.string(),
  }),
  z.object({ version: z.literal(1), type: z.literal("error"), message: z.string() }),
  z.object({
    version: z.literal(1),
    type: z.enum([
      "saved_file",
      "saved_link",
      "offered",
      "retained_upload",
      "connection_closed",
    ]),
  }),
]);
export type AirDropOffer = z.infer<typeof offerSchema>;
export interface AirDropTransferProgress {
  fraction?: number;
  totalBytes?: number;
  transferredBytes: number;
}
export interface AirDropIntake {
  complete(paths: string[]): Promise<void>;
  cancel(reason?: string): void;
  progress(progress: AirDropTransferProgress): void;
}
export interface AirDropFile {
  sequence: number;
  path: string;
  name: string;
  kind: "file" | "directory";
  size: number;
  receivedAt: string;
}
export interface AirDropOptions {
  binaryPath?: string | undefined;
  dataDir: string;
  platform?: string;
  /** The name nearby devices see, read each time the receiver starts. */
  resolveName?: () => Promise<string>;
  onOffer?: (
    offer: AirDropOffer,
    signal: AbortSignal
  ) => Promise<AirDropIntake | undefined>;
  log?: { warn(message: string): void };
}
interface PendingOffer {
  controller: AbortController;
  timer: ReturnType<typeof setTimeout>;
  intake?: AirDropIntake;
  paths: string[];
}

/** Main owns a persistent anonymous listener. Every transfer requires local consent. */
export class AirDropService {
  readonly #options: AirDropOptions;
  readonly #offers = new Map<string, PendingOffer>();
  #prompting = false;
  #child: ChildProcessWithoutNullStreams | undefined;
  #closed: Promise<void> = Promise.resolve();
  #mutations: Promise<unknown> = Promise.resolve();
  #records: Promise<void> = Promise.resolve();
  #phase: "idle" | "starting" | "receiving" | "stopping" | "failed" = "idle";
  #receiverId: string | undefined;
  #directory: string | undefined;
  #name = "Comma";
  #port: number | undefined;
  #error: string | undefined;
  #files: AirDropFile[] = [];
  #sequence = 0;
  #disposed = false;

  constructor(options: AirDropOptions) {
    this.#options = options;
  }

  status() {
    const supported = (this.#options.platform ?? process.platform) === "darwin";
    const available =
      supported && !!this.#options.binaryPath && existsSync(this.#options.binaryPath);
    return {
      available,
      status: this.#phase,
      name: this.#name,
      identity: "anonymous" as const,
      requiresApproval: true,
      receiverId: this.#receiverId,
      directory: this.#directory,
      port: this.#port,
      receivedCount: this.#sequence,
      error: this.#error,
      reason: !supported
        ? "AirDrop requires macOS."
        : !available
          ? "OpenDropKit helper is not installed. Build the AirDrop native helper."
          : undefined,
    };
  }

  /**
   * Starts the receiver, or keeps the running one. `rename` reads the name
   * again and restarts a running receiver whose name changed.
   */
  start({ rename = false }: { rename?: boolean } = {}) {
    return this.#serialize(async () => {
      if (this.#disposed) throw new Error("AirDrop service is closed.");
      const status = this.status();
      if (!status.available || (this.#child && !rename)) return status;
      const name = (await this.#options.resolveName?.()) ?? "Comma";
      // The helper advertises the name it started with; a new name needs a
      // new receiver, which ends a transfer in flight.
      if (this.#child) {
        if (name === this.#name) return status;
        await this.#stop();
      }
      this.#name = name;
      await this.#records;
      this.#receiverId = randomUUID();
      this.#directory = join(this.#options.dataDir, "received", this.#receiverId);
      await mkdir(this.#directory, { recursive: true, mode: 0o700 });
      this.#directory = await realpath(this.#directory);
      this.#files = [];
      this.#sequence = 0;
      this.#error = undefined;
      this.#port = undefined;
      this.#phase = "starting";
      const child = spawn(
        this.#options.binaryPath!,
        [
          "receive",
          "--name",
          name,
          "--directory",
          this.#directory,
          "--identity-directory",
          join(this.#options.dataDir, "identity"),
          "--port",
          "0",
          "--json",
          "--require-approval",
          "--exit-on-stdin-close",
          "--max-connections",
          "4",
        ],
        { stdio: ["pipe", "pipe", "pipe"], shell: false }
      );
      this.#child = child;
      const decoder = new StringDecoder("utf8");
      let pending = "",
        stderr = "";
      let ready!: () => void;
      const startup = new Promise<void>((resolve) => {
        ready = resolve;
      });
      const fail = (message: string) => {
        this.#error = message;
        this.#phase = "failed";
        child.kill("SIGTERM");
        ready();
      };
      const startupTimer = setTimeout(
        () => fail("AirDrop did not start within 8 seconds."),
        8_000
      );
      child.stderr.on("data", (chunk: Buffer) => {
        stderr = (stderr + chunk.toString("utf8")).slice(-4096);
      });
      child.stdin.on("error", () => undefined);
      child.stdout.on("data", (chunk: Buffer) => {
        pending += decoder.write(chunk);
        if (pending.length > 1024 * 1024) {
          pending = "";
          fail("AirDrop event exceeds the size limit.");
          return;
        }
        let newline: number;
        while ((newline = pending.indexOf("\n")) !== -1) {
          const line = pending.slice(0, newline);
          pending = pending.slice(newline + 1);
          try {
            const event = eventSchema.parse(JSON.parse(line));
            if (event.type === "listening" && this.#phase === "starting") {
              this.#port = event.port;
              this.#phase = "receiving";
              ready();
            } else if (event.type === "approval_requested") {
              void this.#approve(event, child);
            } else if (event.type === "transfer_saved") {
              const directory = this.#directory!;
              this.#records = this.#records
                .then(() => this.#receive(event, directory))
                .catch((error: unknown) => {
                  this.#error =
                    error instanceof Error
                      ? error.message
                      : "Could not attach the received file.";
                  this.#cancelOffer(event.requestId, this.#error);
                });
            } else if (event.type === "transfer_failed") {
              this.#cancelOffer(event.requestId, event.message);
            } else if (event.type === "transfer_progress") {
              // Only an approved offer has an intake to hear about its bytes.
              this.#offers.get(event.requestId)?.intake?.progress({
                transferredBytes: event.transferredBytes,
                ...(event.totalBytes === undefined
                  ? {}
                  : { totalBytes: event.totalBytes }),
                ...(event.fraction === undefined ? {} : { fraction: event.fraction }),
              });
            } else if (event.type === "transfer_warning") {
              // Saved sizes differ from the offer; the files still arrive.
              this.#options.log?.warn("AirDrop saved sizes differ from the offer.");
            } else if (event.type === "error") {
              this.#error = event.message.slice(0, 4096);
              this.#options.log?.warn("AirDrop receive failed.");
            }
          } catch {
            fail("Invalid AirDrop helper event. Rebuild the native helper.");
          }
        }
      });
      this.#closed = new Promise<void>((resolve) => {
        child.once("error", (error) => {
          this.#error = error.message;
        });
        child.once("close", () => {
          clearTimeout(startupTimer);
          this.#port = undefined;
          this.#child = undefined;
          this.#cancelAll("AirDrop receiver stopped before the transfer completed.");
          if (this.#phase !== "stopping") {
            this.#error ??= stderr.trim() || "AirDrop receiver exited unexpectedly.";
            this.#phase = "failed";
            this.#options.log?.warn("AirDrop receiver exited unexpectedly.");
          } else {
            this.#phase = "idle";
          }
          ready();
          resolve();
        });
      });
      await startup;
      clearTimeout(startupTimer);
      if (this.status().status !== "receiving" && this.#child) {
        await this.#stop();
        this.#phase = "failed";
      }
      return this.status();
    });
  }

  async #approve(offer: AirDropOffer, child: ChildProcessWithoutNullStreams) {
    const respond = (accept: boolean) => {
      if (this.#child === child && !child.stdin.destroyed)
        child.stdin.write(
          JSON.stringify({
            type: "approval_response",
            requestId: offer.requestId,
            accept,
          }) + "\n"
        );
    };
    if (
      this.#prompting ||
      this.#offers.size >= 4 ||
      !this.#options.onOffer ||
      this.#phase !== "receiving"
    ) {
      respond(false);
      return;
    }
    const controller = new AbortController();
    const pending: PendingOffer = {
      controller,
      paths: [],
      timer: setTimeout(() => this.#cancelOffer(offer.requestId), 25_000),
    };
    this.#offers.set(offer.requestId, pending);
    this.#prompting = true;
    try {
      const intake = await this.#options.onOffer(offer, controller.signal);
      if (
        !intake ||
        controller.signal.aborted ||
        this.#offers.get(offer.requestId) !== pending
      ) {
        intake?.cancel();
        this.#cancelOffer(offer.requestId);
        respond(false);
        return;
      }
      pending.intake = intake;
      clearTimeout(pending.timer);
      pending.timer = setTimeout(
        () =>
          this.#cancelOffer(
            offer.requestId,
            "AirDrop transfer timed out. Received files remain on this Mac."
          ),
        5 * 60_000
      );
      respond(true);
    } catch (error) {
      this.#error = error instanceof Error ? error.message : "AirDrop approval failed.";
      this.#cancelOffer(offer.requestId);
      respond(false);
    } finally {
      this.#prompting = false;
    }
  }

  async #receive(
    event: { requestId: string; paths: string[]; complete: boolean },
    directory: string
  ) {
    const pending = this.#offers.get(event.requestId);
    if (!pending?.intake || pending.controller.signal.aborted) return;
    for (const source of event.paths) {
      const path = await realpath(source);
      const within = relative(directory, path);
      if (!within || within === ".." || within.startsWith("../") || isAbsolute(within))
        throw new Error("Received file is outside the AirDrop directory.");
      const stat = await lstat(path);
      if (!stat.isFile() && !stat.isDirectory())
        throw new Error("Unsupported received file type.");
      pending.paths.push(path);
      this.#files.push({
        sequence: ++this.#sequence,
        path,
        name: basename(path),
        kind: stat.isDirectory() ? "directory" : "file",
        size: stat.size,
        receivedAt: new Date().toISOString(),
      });
      if (this.#files.length > 200) this.#files.shift();
    }
    if (pending.paths.length > 50) throw new Error("Too many received attachments.");
    if (event.complete) {
      await pending.intake.complete(pending.paths);
      clearTimeout(pending.timer);
      this.#offers.delete(event.requestId);
    }
  }

  #cancelOffer(id: string, reason?: string) {
    const pending = this.#offers.get(id);
    if (!pending) return;
    this.#offers.delete(id);
    clearTimeout(pending.timer);
    pending.intake?.cancel(reason);
    pending.controller.abort();
  }
  #cancelAll(reason: string) {
    for (const id of this.#offers.keys()) this.#cancelOffer(id, reason);
  }

  async files(receiverId: string, after = 0, limit = 50) {
    await this.#records;
    if (receiverId !== this.#receiverId)
      throw new Error("AirDrop receiver ID is no longer current. Query status.");
    const files = this.#files.filter((file) => file.sequence > after).slice(0, limit);
    return {
      receiverId,
      directory: this.#directory,
      files,
      nextCursor: files.at(-1)?.sequence ?? after,
      hasMore: (files.at(-1)?.sequence ?? after) < this.#sequence,
      truncated: after < (this.#files[0]?.sequence ?? 1) - 1,
      status: this.#phase,
      error: this.#error,
    };
  }
  stop(receiverId?: string) {
    return this.#serialize(async () => {
      if (receiverId && receiverId !== this.#receiverId)
        throw new Error("AirDrop receiver ID is no longer current.");
      await this.#stop();
      return this.status();
    });
  }
  close() {
    this.#disposed = true;
    return this.stop();
  }
  async #stop() {
    this.#cancelAll("AirDrop receiver stopped before the transfer completed.");
    const child = this.#child;
    if (child) {
      this.#phase = "stopping";
      child.stdin.end();
      child.kill("SIGTERM");
      const timer = setTimeout(() => child.kill("SIGKILL"), 2_000);
      try {
        await this.#closed;
      } finally {
        clearTimeout(timer);
      }
    }
    await this.#records;
  }
  #serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#mutations.then(operation);
    this.#mutations = result.catch(() => undefined);
    return result;
  }
}
