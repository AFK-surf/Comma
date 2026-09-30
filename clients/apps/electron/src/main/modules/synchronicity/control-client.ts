import { existsSync, realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join, posix } from "node:path";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { blake3 } from "@noble/hashes/blake3.js";
import { parse } from "protobufjs";
import controlProto from "./control.proto?raw";

export const synchControlWireVersion = "6";
const CONTROL_VERSION = synchControlWireVersion;
const TOKEN_FILE = "control.token";
const TOKEN_BYTES = 32;
const VERSION_HEADER = "x-synch-control-version";
const TOKEN_HEADER = "x-synch-control-token-bin";
const ERROR_CODE_HEADER = "x-synch-error-code";
const DEFAULT_CALL_TIMEOUT_MS = 30_000;
const DEFAULT_STREAM_TIMEOUT_MS = 15 * 60_000;
const PUT_CHUNK_BYTES = 256 * 1024;

const packageDefinition = protoLoader.fromJSON(parse(controlProto).root.toJSON(), {
  bytes: Buffer,
  defaults: false,
  enums: String,
  keepCase: false,
  longs: String,
  oneofs: true,
});
const loaded = grpc.loadPackageDefinition(packageDefinition) as unknown as {
  synch: {
    control: {
      v1: {
        Control: grpc.ServiceClientConstructor;
      };
    };
  };
};
const ControlConstructor = loaded.synch.control.v1.Control;

/** The exact v1 service definition, also used by transport-level tests. */
export const synchControlServiceDefinition = ControlConstructor.service;

export type SynchControlEntryKind = "file" | "dir" | "symlink" | "tombstone" | "socket";

export interface SynchControlEntry {
  contentRoot: string;
  kind: SynchControlEntryKind;
  mtimeNs: bigint;
  origin: string;
  path: string;
  size: number;
  space: string;
  versions: number;
}

export interface SynchControlSpace {
  budget?: number | undefined;
  checkoutPath?: string | undefined;
  graceSecs: bigint;
  heldBytes?: number | undefined;
  id: string;
  retention?: string | undefined;
  sourceKind?: string | undefined;
  sourcePath?: string | undefined;
  sourcePaused?: boolean | undefined;
  wanted?: number | undefined;
}

export interface SynchControlCommandResult {
  chunks: Uint8Array[];
  lines: string[];
  progress: string[];
  stdout: string;
}

export type SynchControlCommand =
  | { adoptPath: { reference: string; select?: string | undefined } }
  | {
      adoptTree: {
        dryRun: boolean;
        reference: string;
        replace: boolean;
        select?: string | undefined;
      };
    }
  | { daemonStop: Record<string, never> }
  | { domainSet: { delegate: boolean; domain: string } }
  | { id: Record<string, never> }
  | { peerLs: Record<string, never> }
  | { pinAdd: { select?: string | undefined; target: string } }
  | { pinLs: Record<string, never> }
  | { pinRm: { select?: string | undefined; target: string } }
  | {
      replicaAdd: {
        budget?: number | undefined;
        checkout?: string | undefined;
        grace?: number | undefined;
        retention: string;
        space: string;
      };
    }
  | { replicaRm: { pinHeld: boolean; space: string } }
  | {
      replicaSet: {
        budget?: number | undefined;
        checkout?: string | undefined;
        grace?: number | undefined;
        noBudget: boolean;
        noCheckout: boolean;
        retention?: string | undefined;
        space: string;
      };
    }
  | { replicaSync: { space: string } }
  | { sourceAdd: { api: boolean; path: string; space: string } }
  | { sourceLs: { space: string } }
  | { sourceRm: { space: string } }
  | { sourceScan: { space: string } }
  | { sourceSetPaused: { space: string; paused: boolean } }
  | { status: { reference?: string | undefined } };

export interface SynchControlClientLike {
  close(): void;
  delete(input: { path: string; space: string }): Promise<{ stillPublished: boolean }>;
  list(input: {
    limit?: number | undefined;
    policy?: string | undefined;
    prefix: string;
    space: string;
    startAfter?: string | undefined;
  }): Promise<{ entries: SynchControlEntry[]; nextCursor: string }>;
  listSpaces(): Promise<SynchControlSpace[]>;
  put(input: {
    chunks: AsyncIterable<Uint8Array>;
    path: string;
    space: string;
  }): Promise<SynchControlEntry>;
  read(input: {
    len?: number | undefined;
    path: string;
    policy?: string | undefined;
    space: string;
    start: number;
  }): AsyncIterable<Uint8Array>;
  resolve(input: {
    path: string;
    policy?: string | undefined;
    space: string;
  }): Promise<SynchControlEntry>;
  run(command: SynchControlCommand): Promise<SynchControlCommandResult>;
}

export class SynchControlError extends Error {
  constructor(
    message: string,
    readonly code: string,
    options: { cause?: unknown } = {}
  ) {
    super(message, options);
    this.name = "SynchControlError";
  }
}

interface RawControlClient extends grpc.Client {
  delete(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions,
    callback: (error: grpc.ServiceError | null, response?: unknown) => void
  ): grpc.ClientUnaryCall;
  list(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions
  ): grpc.ClientReadableStream<unknown>;
  listSpaces(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions
  ): grpc.ClientReadableStream<unknown>;
  put(
    metadata: grpc.Metadata,
    options: grpc.CallOptions
  ): grpc.ClientDuplexStream<unknown, unknown>;
  read(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions
  ): grpc.ClientReadableStream<unknown>;
  resolve(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions,
    callback: (error: grpc.ServiceError | null, response?: unknown) => void
  ): grpc.ClientUnaryCall;
  run(
    request: unknown,
    metadata: grpc.Metadata,
    options: grpc.CallOptions
  ): grpc.ClientReadableStream<unknown>;
}

interface RawEntry {
  content?: Buffer | undefined;
  kind?: string | undefined;
  mtimeNs?: string | number | undefined;
  origin?: string | undefined;
  path?: string | undefined;
  size?: string | number | undefined;
  space?: string | undefined;
  versions?: number | undefined;
}

interface RawListItem {
  entry?: RawEntry | undefined;
  item?: "entry" | "scanCursor" | undefined;
  scanCursor?: string | undefined;
}

interface RawSpace {
  budget?: string | number | undefined;
  checkoutPath?: string | undefined;
  graceSecs?: string | number | undefined;
  heldBytes?: string | number | undefined;
  id?: string | undefined;
  retention?: string | undefined;
  sourceKind?: string | undefined;
  sourcePath?: string | undefined;
  sourcePaused?: boolean | undefined;
  wanted?: string | number | undefined;
}

interface RawFrame {
  chunk?: Buffer | undefined;
  line?: string | undefined;
  payload?: "chunk" | "line" | "progress" | undefined;
  progress?: string | undefined;
}

interface RawWritten {
  entry?: RawEntry | undefined;
}

/**
 * Main-only client for the daemon's authenticated local control protocol.
 * The token is intentionally read for every attempt: daemon restart rotates
 * it atomically, and no credential remains cached beyond one RPC attempt.
 */
export class SynchControlClient implements SynchControlClientLike {
  readonly #callTimeoutMs: number;
  #client: RawControlClient | undefined;
  readonly #dataDir: string;
  readonly #platform: NodeJS.Platform;
  readonly #streamTimeoutMs: number;

  constructor({
    callTimeoutMs = DEFAULT_CALL_TIMEOUT_MS,
    dataDir,
    platform = process.platform,
    streamTimeoutMs = DEFAULT_STREAM_TIMEOUT_MS,
  }: {
    callTimeoutMs?: number | undefined;
    dataDir: string;
    platform?: NodeJS.Platform | undefined;
    streamTimeoutMs?: number | undefined;
  }) {
    this.#callTimeoutMs = callTimeoutMs;
    this.#dataDir = dataDir;
    this.#platform = platform;
    this.#streamTimeoutMs = streamTimeoutMs;
  }

  close() {
    this.#client?.close();
    this.#client = undefined;
  }

  async list(input: {
    limit?: number | undefined;
    policy?: string | undefined;
    prefix: string;
    space: string;
    startAfter?: string | undefined;
  }): Promise<{ entries: SynchControlEntry[]; nextCursor: string }> {
    return this.#retryRead(async (client) => {
      const stream = client.list(
        {
          ...(input.limit === undefined ? {} : { limit: input.limit }),
          ...(input.policy ? { policy: input.policy } : {}),
          prefix: input.prefix,
          space: input.space,
          ...(input.startAfter ? { startAfter: input.startAfter } : {}),
        },
        await this.#metadata(),
        this.#streamOptions()
      );
      const entries: SynchControlEntry[] = [];
      let scanCursor = "";
      for await (const raw of stream) {
        const item = raw as RawListItem;
        if (item.item === "entry" && item.entry) entries.push(mapEntry(item.entry));
        if (item.item === "scanCursor") scanCursor = item.scanCursor ?? "";
      }
      return {
        entries,
        nextCursor:
          scanCursor ||
          (input.limit !== undefined && entries.length >= input.limit
            ? (entries.at(-1)?.path ?? "")
            : ""),
      };
    });
  }

  async resolve(input: {
    path: string;
    policy?: string | undefined;
    space: string;
  }): Promise<SynchControlEntry> {
    return this.#retryRead(async (client) => {
      const metadata = await this.#metadata();
      const response = await unaryCall<RawEntry>((callback) =>
        client.resolve(
          {
            path: input.path,
            ...(input.policy ? { policy: input.policy } : {}),
            space: input.space,
          },
          metadata,
          this.#options(),
          callback
        )
      );
      return mapEntry(response);
    });
  }

  async *read(input: {
    len?: number | undefined;
    path: string;
    policy?: string | undefined;
    space: string;
    start: number;
  }): AsyncGenerator<Uint8Array> {
    let attempt = 0;
    let yielded = false;
    for (;;) {
      const client = this.#clientForCall();
      try {
        const stream = client.read(
          {
            ...(input.len === undefined ? {} : { len: input.len }),
            path: input.path,
            ...(input.policy ? { policy: input.policy } : {}),
            space: input.space,
            start: input.start,
          },
          await this.#metadata(),
          this.#streamOptions()
        );
        for await (const raw of stream) {
          const data = (raw as { data?: Buffer }).data;
          if (!data)
            throw new SynchControlError("control Read omitted chunk data", "invalid");
          yielded = true;
          yield data;
        }
        return;
      } catch (error) {
        if (yielded || attempt > 0 || !retryableRead(error)) throw controlError(error);
        attempt += 1;
        this.#reconnect(client);
      }
    }
  }

  async put(input: {
    chunks: AsyncIterable<Uint8Array>;
    path: string;
    space: string;
  }): Promise<SynchControlEntry> {
    let stream: grpc.ClientDuplexStream<unknown, unknown> | undefined;
    let responses: Promise<RawWritten[]> | undefined;
    for (let attempt = 0; ; attempt += 1) {
      const client = this.#clientForCall();
      try {
        stream = client.put(await this.#metadata(), this.#streamOptions());
        responses = collectStream<RawWritten>(stream);
        void responses.catch(() => undefined);
        // Listen before the header write: a local daemon can accept it and
        // answer quickly enough for response metadata to beat the writable
        // callback that confirms the client-side buffer drained.
        const accepted = responseMetadata(stream);
        void accepted.catch(() => undefined);
        await writePart(stream, {
          header: { path: input.path, space: input.space },
        });
        await accepted;
        break;
      } catch (error) {
        stream?.cancel();
        await responses?.catch(() => []);
        if (attempt > 0 || !retryableRead(error)) throw controlError(error);
        this.#reconnect(client);
      }
    }
    try {
      for await (const chunk of input.chunks) {
        for (let offset = 0; offset < chunk.byteLength; offset += PUT_CHUNK_BYTES) {
          await writePart(stream, {
            chunk: Buffer.from(
              chunk.buffer,
              chunk.byteOffset + offset,
              Math.min(PUT_CHUNK_BYTES, chunk.byteLength - offset)
            ),
          });
        }
      }
      await writePart(stream, { commit: {} });
      stream.end();
      const written = await responses;
      const entry = written[0]?.entry;
      if (written.length !== 1 || !entry) {
        throw new SynchControlError(
          "control Put returned an invalid result",
          "invalid"
        );
      }
      return mapEntry(entry);
    } catch (error) {
      if (!stream.destroyed) {
        try {
          await writePart(stream, { abort: safeAbortReason(error) });
          stream.end();
          await responses.catch(() => []);
        } catch {
          stream.cancel();
        }
      }
      throw controlError(error);
    }
  }

  async delete(input: {
    path: string;
    space: string;
  }): Promise<{ stillPublished: boolean }> {
    const attempt = async (client: RawControlClient) => {
      const metadata = await this.#metadata();
      return unaryCall<{ stillPublished?: boolean }>((callback) =>
        client.delete(input, metadata, this.#options(), callback)
      );
    };
    const client = this.#clientForCall();
    try {
      const result = await attempt(client);
      return { stillPublished: result.stillPublished ?? false };
    } catch (error) {
      if (!retryableAuthentication(error)) throw controlError(error);
      this.#reconnect(client);
      try {
        const result = await attempt(this.#clientForCall());
        return { stillPublished: result.stillPublished ?? false };
      } catch (retryError) {
        throw controlError(retryError);
      }
    }
  }

  async listSpaces(): Promise<SynchControlSpace[]> {
    return this.#retryRead(async (client) => {
      const stream = client.listSpaces(
        {},
        await this.#metadata(),
        this.#streamOptions()
      );
      return (await collectStream<RawSpace>(stream)).map(mapSpace);
    });
  }

  async run(command: SynchControlCommand): Promise<SynchControlCommandResult> {
    const attempt = async (client: RawControlClient) => {
      const stream = client.run(command, await this.#metadata(), this.#streamOptions());
      const frames = await collectStream<RawFrame>(stream);
      const lines: string[] = [];
      const chunks: Uint8Array[] = [];
      const progress: string[] = [];
      for (const frame of frames) {
        if (frame.payload === "line") lines.push(frame.line ?? "");
        if (frame.payload === "chunk" && frame.chunk) chunks.push(frame.chunk);
        if (frame.payload === "progress") progress.push(frame.progress ?? "");
      }
      return {
        chunks,
        lines,
        progress,
        stdout: lines.length > 0 ? `${lines.join("\n")}\n` : "",
      };
    };
    const client = this.#clientForCall();
    try {
      return await attempt(client);
    } catch (error) {
      if (!retryableRun(command, error)) throw controlError(error);
      this.#reconnect(client);
      try {
        return await attempt(this.#clientForCall());
      } catch (retryError) {
        throw controlError(retryError);
      }
    }
  }

  async #metadata(): Promise<grpc.Metadata> {
    let token: Buffer;
    try {
      token = await readFile(join(this.#dataDir, TOKEN_FILE));
    } catch (error) {
      if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        throw new SynchControlError(
          "the Synchronicity daemon control token is not available",
          "unavailable",
          { cause: error }
        );
      }
      throw error;
    }
    if (token.byteLength !== TOKEN_BYTES) {
      throw new SynchControlError(
        `control token must be ${TOKEN_BYTES} bytes, received ${token.byteLength}`,
        "unauthorized"
      );
    }
    const metadata = new grpc.Metadata();
    metadata.set(VERSION_HEADER, CONTROL_VERSION);
    metadata.set(TOKEN_HEADER, token);
    return metadata;
  }

  #options(): grpc.CallOptions {
    return { deadline: Date.now() + this.#callTimeoutMs };
  }

  #streamOptions(): grpc.CallOptions {
    return { deadline: Date.now() + this.#streamTimeoutMs };
  }

  #createClient(): RawControlClient {
    return new ControlConstructor(
      synchControlEndpoint(this.#dataDir, this.#platform),
      grpc.credentials.createInsecure(),
      {
        "grpc.max_receive_message_length": 16 * 1024 * 1024,
        "grpc.max_send_message_length": 16 * 1024 * 1024,
      }
    ) as unknown as RawControlClient;
  }

  #clientForCall() {
    // Main constructs this service before it creates a first-run datadir. In
    // particular, Windows hashes the canonical existing path for its pipe, so
    // derive the endpoint only when the first authenticated call actually runs.
    return (this.#client ??= this.#createClient());
  }

  #reconnect(failed: RawControlClient) {
    if (this.#client !== failed) return;
    failed.close();
    this.#client = undefined;
  }

  async #retryRead<T>(operation: (client: RawControlClient) => Promise<T>): Promise<T> {
    const client = this.#clientForCall();
    try {
      return await operation(client);
    } catch (error) {
      if (!retryableRead(error)) throw controlError(error);
      this.#reconnect(client);
      try {
        return await operation(this.#clientForCall());
      } catch (retryError) {
        throw controlError(retryError);
      }
    }
  }
}

/**
 * grpc-js uses its Unix resolver for both POSIX sockets and Windows pipe
 * paths. The daemon names its pipe after the data directory
 * (`synch-cli/src/control/transport.rs`, `endpoint_name`): the first 16 hex
 * of the blake3 of the path as Rust's `canonicalize` prints it when the
 * directory exists, the raw text when it does not. Rust's canonical form is
 * the verbatim one — `\\?\\C:\\…`, `\\?\\UNC\\server\\share\\…` — which Node's
 * realpath strips, so the prefix is put back before hashing.
 */
export function synchControlEndpoint(
  dataDir: string,
  platform: NodeJS.Platform = process.platform
): string {
  if (platform !== "win32") return `unix:${posix.join(dataDir, "control.sock")}`;
  const resolved = existsSync(dataDir)
    ? verbatimWindowsPath(realpathSync.native(dataDir))
    : dataDir;
  const hash = Buffer.from(blake3(Buffer.from(resolved)))
    .toString("hex")
    .slice(0, 16);
  return `unix:\\\\.\\pipe\\synchronicity-${hash}`;
}

function verbatimWindowsPath(path: string): string {
  if (path.startsWith("\\\\?\\")) return path;
  if (path.startsWith("\\\\")) return `\\\\?\\UNC\\${path.slice(2)}`;
  return `\\\\?\\${path}`;
}

function unaryCall<T>(
  start: (
    callback: (error: grpc.ServiceError | null, response?: unknown) => void
  ) => grpc.ClientUnaryCall | void
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    start((error, response) => {
      if (error) reject(error);
      else resolve(response as T);
    });
  });
}

function collectStream<T>(stream: NodeJS.ReadableStream): Promise<T[]> {
  return new Promise<T[]>((resolve, reject) => {
    const values: T[] = [];
    stream.on("data", (value: T) => values.push(value));
    stream.once("error", reject);
    stream.once("end", () => resolve(values));
  });
}

function responseMetadata(stream: grpc.ClientDuplexStream<unknown, unknown>) {
  return new Promise<void>((resolve, reject) => {
    const onMetadata = () => {
      cleanup();
      resolve();
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      stream.off("metadata", onMetadata);
      stream.off("error", onError);
    };
    stream.once("metadata", onMetadata);
    stream.once("error", onError);
  });
}

function writePart(
  stream: grpc.ClientDuplexStream<unknown, unknown>,
  part: Record<string, unknown>
) {
  return new Promise<void>((resolve, reject) => {
    stream.write(part, (error?: Error | null) => (error ? reject(error) : resolve()));
  });
}

function mapEntry(raw: RawEntry): SynchControlEntry {
  const kind = entryKinds[raw.kind ?? ""];
  if (!kind || !raw.origin || !raw.path || !raw.space) {
    throw new SynchControlError("control returned an invalid entry", "invalid");
  }
  return {
    contentRoot: raw.content ? raw.content.toString("hex") : "",
    kind,
    mtimeNs: BigInt(raw.mtimeNs ?? 0),
    origin: raw.origin,
    path: raw.path,
    size: safeNumber(raw.size ?? 0, "entry size"),
    space: raw.space,
    versions: safeNumber(raw.versions ?? 0, "entry versions"),
  };
}

function mapSpace(raw: RawSpace): SynchControlSpace {
  if (!raw.id)
    throw new SynchControlError("control returned a space without an id", "invalid");
  return {
    ...(raw.budget === undefined ? {} : { budget: safeNumber(raw.budget, "budget") }),
    ...(raw.checkoutPath === undefined ? {} : { checkoutPath: raw.checkoutPath }),
    graceSecs: BigInt(raw.graceSecs ?? 0),
    ...(raw.heldBytes === undefined
      ? {}
      : { heldBytes: safeNumber(raw.heldBytes, "held bytes") }),
    id: raw.id,
    ...(raw.retention === undefined ? {} : { retention: raw.retention }),
    ...(raw.sourceKind === undefined ? {} : { sourceKind: raw.sourceKind }),
    ...(raw.sourcePath === undefined ? {} : { sourcePath: raw.sourcePath }),
    ...(raw.sourcePaused === undefined ? {} : { sourcePaused: raw.sourcePaused }),
    ...(raw.wanted === undefined ? {} : { wanted: safeNumber(raw.wanted, "wanted") }),
  };
}

const entryKinds: Record<string, SynchControlEntryKind | undefined> = {
  ENTRY_KIND_DIR: "dir",
  ENTRY_KIND_FILE: "file",
  ENTRY_KIND_SOCKET: "socket",
  ENTRY_KIND_SYMLINK: "symlink",
  ENTRY_KIND_TOMBSTONE: "tombstone",
};

function safeNumber(value: string | number, label: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new SynchControlError(`control returned an invalid ${label}`, "invalid");
  }
  return parsed;
}

function controlError(error: unknown): SynchControlError {
  if (error instanceof SynchControlError) return error;
  const candidate = error as Partial<grpc.ServiceError> | undefined;
  const grpcCode = typeof candidate?.code === "number" ? candidate.code : undefined;
  const metadataCode = candidate?.metadata?.get(ERROR_CODE_HEADER)[0];
  const code =
    typeof metadataCode === "string"
      ? metadataCode
      : grpcCode === undefined
        ? "internal"
        : grpc.status[grpcCode]?.toLowerCase().replaceAll("_", "-") || "internal";
  const message = candidate?.details || candidate?.message || String(error);
  return new SynchControlError(message, code, { cause: error });
}

function retryableRead(error: unknown): boolean {
  if (error instanceof SynchControlError) {
    return error.code === "unavailable" || error.code === "unauthorized";
  }
  const code = (error as Partial<grpc.ServiceError> | undefined)?.code;
  return code === grpc.status.UNAVAILABLE || code === grpc.status.UNAUTHENTICATED;
}

function retryableAuthentication(error: unknown): boolean {
  if (error instanceof SynchControlError) return error.code === "unauthorized";
  return (
    (error as Partial<grpc.ServiceError> | undefined)?.code ===
    grpc.status.UNAUTHENTICATED
  );
}

function retryableRun(command: SynchControlCommand, error: unknown): boolean {
  return (
    retryableAuthentication(error) || (readOnlyCommand(command) && retryableRead(error))
  );
}

function readOnlyCommand(command: SynchControlCommand): boolean {
  return (
    "id" in command ||
    "peerLs" in command ||
    "pinLs" in command ||
    "sourceLs" in command ||
    "status" in command
  );
}

function safeAbortReason(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return message.replaceAll(/[\r\n]/g, " ").slice(0, 256) || "source failed";
}
