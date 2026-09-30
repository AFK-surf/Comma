import { spawn, type ChildProcess } from "node:child_process";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import { isAbsolute, join } from "node:path";
import { fileDownloadMaxBytes } from "@comma/native-bridge";
import type {
  FilesSaveDownloadResult,
  SynchronicityAdoptInput,
  SynchronicityAdoptTreeInput,
  SynchronicityAdoptTreeResult,
  SynchronicityDeleteInput,
  SynchronicityImportFileInput,
  SynchronicityListInput,
  SynchronicityListResult,
  SynchronicityMutationResult,
  SynchronicityPickFolderResult,
  SynchronicityPinInput,
  SynchronicityReadInput,
  SynchronicityReadResult,
  SynchronicityReplicaSetInput,
  SynchronicityReplicaSyncInput,
  SynchronicityReplicaSyncResult,
  SynchronicitySetDomainInput,
  SynchronicitySaveDownloadInput,
  SynchronicityOpenLocalRootResult,
  SynchronicitySourceAddInput,
  SynchronicitySourceRemoveInput,
  SynchronicitySpace,
  SynchronicitySpaceSettingsInput,
  SynchronicityState,
  SynchronicityVersion,
  SynchronicityVersionsInput,
  SynchronicityVersionsResult,
  SynchronicityWriteInput,
} from "@comma/native-bridge";
import { z } from "zod";
import {
  prepareDefaultRoot,
  publishedSourcePath,
  sameSourcePath,
  type DefaultSpaceRoot,
} from "./default-root";
import {
  SynchControlClient,
  SynchControlError,
  type SynchControlClientLike,
} from "./control-client";

/**
 * The bundled synchronicity node, owned by Main the way the per-workspace
 * connector is: one daemon per install, in a data directory of its own under
 * userData so it never shares a node with a `synch` the user runs themselves.
 *
 * Main connects straight to the daemon's authenticated gRPC control socket.
 * The renderer sees only the narrower native capabilities below; socket paths,
 * tokens and raw control calls never cross the IPC authority boundary.
 */
export interface SynchronicityProvider {
  subscribeChanges?(listener: () => void): () => void;
  state(input: void): Promise<SynchronicityState> | SynchronicityState;
  list(input: SynchronicityListInput): Promise<SynchronicityListResult>;
  read(input: SynchronicityReadInput): Promise<SynchronicityReadResult>;
  saveDownload(input: SynchronicitySaveDownloadInput): Promise<FilesSaveDownloadResult>;
  openLocalRoot(input: void): Promise<SynchronicityOpenLocalRootResult>;
  versions(input: SynchronicityVersionsInput): Promise<SynchronicityVersionsResult>;
  write(input: SynchronicityWriteInput): Promise<SynchronicityMutationResult>;
  importFile(input: SynchronicityImportFileInput): Promise<SynchronicityMutationResult>;
  delete(input: SynchronicityDeleteInput): Promise<SynchronicityMutationResult>;
  adopt(input: SynchronicityAdoptInput): Promise<SynchronicityMutationResult>;
  scan(input: void): Promise<SynchronicityMutationResult>;
  setDomain(input: SynchronicitySetDomainInput): Promise<SynchronicityState>;
  sourceAdd(input: SynchronicitySourceAddInput): Promise<SynchronicityMutationResult>;
  sourceRemove(
    input: SynchronicitySourceRemoveInput
  ): Promise<SynchronicityMutationResult>;
  replicaSet(input: SynchronicityReplicaSetInput): Promise<SynchronicityMutationResult>;
  replicaSync(
    input: SynchronicityReplicaSyncInput
  ): Promise<SynchronicityReplicaSyncResult>;
  pin(input: SynchronicityPinInput): Promise<SynchronicityMutationResult>;
  adoptTree(input: SynchronicityAdoptTreeInput): Promise<SynchronicityAdoptTreeResult>;
  restart(input: void): Promise<SynchronicityState>;
  pickFolder(input: void): Promise<SynchronicityPickFolderResult>;
  setSpaceSettings(input: SynchronicitySpaceSettingsInput): Promise<SynchronicityState>;
}

/**
 * What this install decides about a space beside the node: the name it shows
 * for it, and whether the cluster's files for a space it publishes are
 * written into its folder as they appear. Kept in the node's own data
 * directory, so it lives and dies with the node.
 */
interface SpaceSettings {
  autoAdopt?: boolean | undefined;
  label?: string | undefined;
}

interface DriveSettingsFile {
  spaces: Record<string, SpaceSettings>;
}

const SETTINGS_FILE = "comma-drive-settings.json";

interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

interface RunCommandOptions {
  signal: AbortSignal;
}

type RunCommand = (
  binary: string,
  args: string[],
  options: RunCommandOptions
) => Promise<CommandResult>;

export interface SynchronicityNodeServiceOptions {
  /** Absent (tests, unbuilt dev): the node reports itself unavailable and nothing is spawned. */
  binaryPath?: string | undefined;
  /** The node's own data directory; never the platform default another node may hold. */
  dataDir: string;
  /** The filesystem source published as the install's default space. */
  defaultSpace: DefaultSpaceRoot;
  /** What this machine calls itself; defaults to its hostname. */
  deviceName?: string | undefined;
  log?: { info(message: string): void; warn(message: string): void } | undefined;
  /** The native folder dialog; resolves to nothing when dismissed. */
  pickFolder?: (() => Promise<string | undefined>) | undefined;
  /** Opens the configured local Drive root; an empty answer means success. */
  openLocalRoot?: ((path: string) => Promise<string>) | undefined;
  /** Incrementally saves verified node bytes under Main-owned Downloads. */
  saveDownload?:
    | ((input: {
        chunks: AsyncIterable<Uint8Array>;
        fileName: string;
      }) => Promise<FilesSaveDownloadResult>)
    | undefined;
  /** Injectable direct-control seam for tests; production owns one gRPC client. */
  control?: SynchControlClientLike | undefined;
  runCommand?: RunCommand | undefined;
}

const DAEMON_START_TIMEOUT_MS = 20_000;
const DAEMON_START_RETRY_MS = 100;
const DAEMON_STOP_TIMEOUT_MS = 20_000;
const COMMAND_TERMINATE_GRACE_MS = 1_000;
const DAEMON_LIFECYCLE_BUSY =
  /another daemon or CAS migration owns this data directory/i;
const IDENTITY_REFRESH_MS = 20_000;

const nodeIdSchema = z.object({
  origin: z.string().min(1),
});

const driveSettingsSchema = z.object({
  spaces: z.record(
    z.string(),
    z.object({
      autoAdopt: z.boolean().optional(),
      label: z.string().optional(),
    })
  ),
});

/**
 * Parses `synch status <ref>` / `synch_versions` rows. The daemon renders
 * versions as text (the CLI's own inspector), one indented line per version:
 *
 *     6019afd609cb9521   file               20  seq 1      key:7fme4gjwoh
 *     (deleted)          deleted             0  seq 4      key:qmpmjtrw6w
 */
export function parseSynchVersions(text: string): SynchronicityVersion[] {
  const versions: SynchronicityVersion[] = [];
  for (const rawLine of text.split("\n")) {
    if (!rawLine.startsWith("    ")) continue;
    const line = rawLine.trim();
    const match = line.match(/^(\S+)\s+(\S+)\s+(\d+)\s+seq\s+(\d+)\s+(.*)$/);
    if (!match) continue;
    const [, root, kind, size, seq, attestors] = match;
    versions.push({
      attestors: attestors!
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean),
      kind: kind === "deleted" ? "tombstone" : kind!,
      root: root === "(deleted)" ? "" : root!,
      seq: Number(seq),
      size: Number(size),
    });
  }
  return versions;
}

/**
 * Parses `synch pin ls`: one line per held object, columns two spaces apart —
 * `<root>  <bytes> B  <holders>  <space>/<path>`, holders comma-separated
 * (`operator, source:comma-drive`). Only the operator's own pins count; sources
 * and replicas hold their content on their own account.
 */
export function parseSynchPins(text: string): string[] {
  const pins: string[] = [];
  for (const line of text.split("\n")) {
    const columns = line.trim().split(/\s{2,}/);
    if (columns.length < 4) continue;
    const holders = columns[2]!.split(",").map((holder) => holder.trim());
    if (holders.includes("operator")) pins.push(columns.slice(3).join("  "));
  }
  return pins;
}

/** Trusted canonical origins in `synch peer ls`; `(untrusted)` rows name none. */
export function parseSynchPeerOrigins(text: string): string[] {
  const origins: string[] = [];
  for (const line of text.split("\n")) {
    const columns = line.trim().split(/\s{2,}/);
    const names = columns[1];
    if (!names || names === "(untrusted)") continue;
    for (const origin of names.split(",")) {
      const canonical = origin.trim();
      if (canonical && !origins.includes(canonical)) origins.push(canonical);
    }
  }
  return origins;
}

/** `would adopt 1 · current 5 · differing 0 · skipped 0`, or `adopted 1 · …` once written. */
export function parseSynchAdoptTree(
  text: string
): Omit<SynchronicityAdoptTreeResult, "status"> {
  const count = (label: string) =>
    Number(text.match(new RegExp(`(?:^|\\s)${label}\\s+(\\d+)`))?.[1] ?? 0);
  return {
    adopt: count("(?:would adopt|adopted)"),
    current: count("current"),
    differing: count("differing"),
    skipped: count("skipped"),
  };
}

/** The checkout line of `synch replica sync`: `checkout <space>  written 2 · current 1 · removed 0 · blocked 0`. */
export function parseSynchReplicaSync(
  text: string
): Omit<SynchronicityReplicaSyncResult, "status"> {
  const line =
    text.split("\n").find((entry) => entry.trim().startsWith("checkout ")) ?? "";
  const count = (label: string) =>
    Number(line.match(new RegExp(`${label}\\s+(\\d+)`))?.[1] ?? 0);
  return {
    blocked: count("blocked"),
    current: count("current"),
    removed: count("removed"),
    written: count("written"),
  };
}

async function runCommand(
  binary: string,
  args: string[],
  options: RunCommandOptions
): Promise<CommandResult> {
  options.signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      detached: process.platform !== "win32",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let aborting = false;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      options.signal.removeEventListener("abort", abort);
      callback();
    };
    const abort = () => {
      if (settled || aborting) return;
      aborting = true;
      void terminateCommandProcessTree(child).finally(() =>
        finish(() => reject(abortReason(options.signal)))
      );
    };
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.once("error", (error) => {
      if (!aborting) finish(() => reject(error));
    });
    child.once("exit", (code) => {
      if (!aborting) {
        finish(() => resolve({ code: code ?? -1, stderr, stdout }));
      }
    });
    options.signal.addEventListener("abort", abort, { once: true });
    if (options.signal.aborted) abort();
  });
}

async function terminateCommandProcessTree(child: ChildProcess): Promise<void> {
  if (!child.pid) {
    child.kill();
    return;
  }

  if (process.platform === "win32") {
    await new Promise<void>((resolve) => {
      let finished = false;
      const done = () => {
        if (finished) return;
        finished = true;
        clearTimeout(fallback);
        resolve();
      };
      const killer = spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
        stdio: "ignore",
        windowsHide: true,
      });
      const fallback = setTimeout(() => {
        child.kill();
        done();
      }, COMMAND_TERMINATE_GRACE_MS);
      fallback.unref();
      killer.once("error", () => {
        child.kill();
        done();
      });
      killer.once("close", done);
    });
    return;
  }

  await new Promise<void>((resolve) => {
    let finished = false;
    const done = () => {
      if (finished) return;
      finished = true;
      clearTimeout(force);
      clearTimeout(fallback);
      resolve();
    };
    const signalGroup = (signal: NodeJS.Signals) => {
      try {
        process.kill(-child.pid!, signal);
      } catch {
        child.kill(signal);
      }
    };
    child.once("close", done);
    signalGroup("SIGTERM");
    const force = setTimeout(() => signalGroup("SIGKILL"), COMMAND_TERMINATE_GRACE_MS);
    const fallback = setTimeout(done, COMMAND_TERMINATE_GRACE_MS * 2);
    force.unref();
    fallback.unref();
  });
}

class SynchronicityLifecycleClosedError extends Error {
  constructor() {
    super("synchronicity node lifecycle is closed");
    this.name = "SynchronicityLifecycleClosedError";
  }
}

export class SynchronicityNodeService implements SynchronicityProvider {
  readonly #listeners = new Set<() => void>();
  subscribeChanges = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  #changed() {
    for (const listener of this.#listeners) listener();
  }

  readonly #control: SynchControlClientLike;
  readonly #options: SynchronicityNodeServiceOptions;
  readonly #run: RunCommand;
  #status: SynchronicityState["status"] = "unavailable";
  #reason: string | undefined;
  #localRoot: string;
  #origin = "";
  #domain = "";
  #identityRefreshedAt = 0;
  #starting: Promise<void> | undefined;
  #lifecycleTail: Promise<void> = Promise.resolve();
  #activeLifecycle: AbortController | undefined;
  #closing: Promise<void> | undefined;
  #closed = false;
  #settings: DriveSettingsFile = { spaces: {} };
  #syncTail: Promise<unknown> = Promise.resolve();

  constructor(options: SynchronicityNodeServiceOptions) {
    this.#options = options;
    this.#localRoot = options.defaultSpace.root;
    this.#run = options.runCommand ?? runCommand;
    this.#control =
      options.control ?? new SynchControlClient({ dataDir: options.dataDir });
  }

  /**
   * Brings the node up: a first run initialises the data directory, the
   * daemon is started (or found already running from a previous session),
   * and the default source is published if it is not yet. Never throws —
   * a node that could not start reports why through `state()`.
   */
  async start(): Promise<void> {
    if (this.#closed) return;
    this.#starting ??= this.#enqueueLifecycle((signal) =>
      this.#startWithReporting(false, signal)
    ).catch((error: unknown) => {
      if (this.#closed || error instanceof SynchronicityLifecycleClosedError) return;
      throw error;
    });
    return this.#starting;
  }

  #startWithReporting(forceDaemonStart: boolean, signal: AbortSignal) {
    return this.#start(forceDaemonStart, signal).catch((error: unknown) => {
      if (this.#closed || signal.aborted) return;
      this.#status = "error";
      this.#reason = error instanceof Error ? error.message : String(error);
      this.#options.log?.warn(`synchronicity node failed to start: ${this.#reason}`);
    });
  }

  async close(): Promise<void> {
    if (this.#closing) return this.#closing;
    this.#closed = true;
    this.#status = "unavailable";
    this.#reason = undefined;
    this.#activeLifecycle?.abort(new SynchronicityLifecycleClosedError());
    this.#closing = this.#enqueueLifecycleTurn(async () => {
      if (this.#options.binaryPath) {
        try {
          await this.#stopDaemon(new AbortController().signal);
        } catch (error) {
          this.#options.log?.warn(
            `synchronicity daemon stop failed: ${error instanceof Error ? error.message : String(error)}`
          );
        }
      }
      this.#control.close();
      this.#status = "unavailable";
      this.#reason = undefined;
    });
    return this.#closing;
  }

  async state(): Promise<SynchronicityState> {
    if (this.#status === "ready") {
      await this.#refreshIdentity().catch((error: unknown) => {
        this.#options.log?.warn(
          `synchronicity identity refresh failed: ${error instanceof Error ? error.message : String(error)}`
        );
      });
    }
    const base: SynchronicityState = {
      dataDir: this.#options.dataDir,
      defaultSpace: this.#options.defaultSpace.id,
      deviceName: this.#options.deviceName ?? hostname().replace(/\.local$/, ""),
      domain: this.#domain,
      localRoot: this.#localRoot,
      origin: this.#origin,
      origins: this.#origin ? [this.#origin] : [],
      pins: [],
      spaces: [],
      status: this.#status,
      ...(this.#reason ? { reason: this.#reason } : {}),
    };
    if (this.#status !== "ready") return base;
    try {
      const [spaces, pins, origins] = await Promise.all([
        this.#spaces(),
        this.#pins(),
        this.#origins(),
      ]);
      return { ...base, origins, pins, spaces };
    } catch (error) {
      return {
        ...base,
        reason: error instanceof Error ? error.message : String(error),
        status: "error",
      };
    }
  }

  async list(input: SynchronicityListInput): Promise<SynchronicityListResult> {
    const result = await this.#control.list({
      limit: input.limit,
      policy: input.policy,
      prefix: input.prefix ?? "",
      space: input.space,
      startAfter: input.cursor,
    });
    return {
      entries: result.entries.map((entry) => ({
        contentRoot: entry.contentRoot,
        kind: entry.kind,
        mtimeMs: Number(entry.mtimeNs / 1_000_000n),
        origin: entry.origin,
        path: entry.path,
        size: entry.size,
        versions: entry.versions,
      })),
      nextCursor: result.nextCursor,
    };
  }

  /** One preview-sized range; raw gRPC bytes become base64 only at Native Bridge. */
  async read(input: SynchronicityReadInput): Promise<SynchronicityReadResult> {
    const reference = {
      path: input.path,
      ...(input.policy ? { policy: input.policy } : {}),
      space: input.space,
    };
    const before = await this.#control.resolve(reference);
    assertReadableFile(before);
    const chunks: Uint8Array[] = [];
    for await (const chunk of this.#control.read({
      ...reference,
      len: input.length,
      start: input.offset,
    })) {
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    const expectedLength = Math.min(
      input.length,
      Math.max(0, before.size - input.offset)
    );
    if (bytes.byteLength !== expectedLength) {
      throw new SynchControlError(
        "control Read returned an invalid byte range",
        "invalid"
      );
    }
    await this.#assertUnchanged(reference, before.contentRoot, before.size);
    return {
      content: bytes.toString("base64"),
      contentRoot: before.contentRoot,
      eof: input.offset + bytes.byteLength >= before.size,
      length: bytes.byteLength,
      offset: input.offset,
      size: before.size,
    };
  }

  async saveDownload(
    input: SynchronicitySaveDownloadInput
  ): Promise<FilesSaveDownloadResult> {
    const save = this.#options.saveDownload;
    if (!save) return { status: "unavailable" };
    return save({ chunks: this.#readChunks(input), fileName: input.fileName });
  }

  async openLocalRoot(): Promise<SynchronicityOpenLocalRootResult> {
    const openRoot = this.#options.openLocalRoot;
    if (!openRoot) return { status: "unavailable" };
    const failure = await openRoot(this.#localRoot);
    return failure ? { status: "unavailable" } : { status: "opened" };
  }

  async versions(
    input: SynchronicityVersionsInput
  ): Promise<SynchronicityVersionsResult> {
    const result = await this.#control.run({
      status: { reference: `${input.space}/${input.path}` },
    });
    return { versions: parseSynchVersions(result.stdout) };
  }

  async write(input: SynchronicityWriteInput): Promise<SynchronicityMutationResult> {
    const bytes = Buffer.from(input.content, "base64");
    if (bytes.byteLength > fileDownloadMaxBytes) {
      throw new SynchControlError(
        "renderer-originated Synchronicity writes are limited to 10 MB",
        "invalid"
      );
    }
    await this.#control.put({
      chunks: singleChunk(bytes),
      path: input.path,
      space: input.space,
    });
    this.#changed();
    return { status: "done" };
  }

  async importFile(
    input: SynchronicityImportFileInput
  ): Promise<SynchronicityMutationResult> {
    if (!isAbsolute(input.sourcePath)) {
      throw new SynchControlError(
        "Synchronicity import source must be absolute",
        "invalid"
      );
    }
    await this.#control.put({
      chunks: lazyFileChunks(input.sourcePath),
      path: input.path,
      space: input.space,
    });
    this.#changed();
    return { status: "done" };
  }

  async delete(input: SynchronicityDeleteInput): Promise<SynchronicityMutationResult> {
    await this.#control.delete({ path: input.path, space: input.space });
    this.#changed();
    return { status: "done" };
  }

  async adopt(input: SynchronicityAdoptInput): Promise<SynchronicityMutationResult> {
    return this.#enqueueSync(async () => {
      if (input.automatic) {
        const enabled =
          this.#settings.spaces[input.space]?.autoAdopt ??
          input.space === this.#options.defaultSpace.id;
        if (!enabled) return { status: "done", skipped: true };
      }
      await this.#control.run({
        adoptPath: {
          reference: `${input.space}/${input.path}`,
          select: input.select,
        },
      });
      this.#changed();
      return { status: "done" };
    });
  }

  async scan(): Promise<SynchronicityMutationResult> {
    await this.#control.run({ sourceScan: { space: "" } });
    this.#changed();
    return { status: "done" };
  }

  /**
   * Binds the node to the membership zone that names it — the `domain` Comma's
   * device enrollment answers with. The daemon reads it at start, so it is
   * restarted here rather than left to pick the name up next session.
   */
  async setDomain(input: SynchronicitySetDomainInput): Promise<SynchronicityState> {
    if (this.#closed) return this.state();
    try {
      return await this.#enqueueLifecycle(async (signal) => {
        await this.#control.run({
          domainSet: { delegate: false, domain: input.domain },
        });
        this.#assertLifecycleOpen(signal);
        await this.#stopDaemon(signal);
        this.#assertLifecycleOpen(signal);
        await this.#startDaemon(true, signal);
        this.#assertLifecycleOpen(signal);
        await this.#refreshIdentity(true);
        this.#assertLifecycleOpen(signal);
        this.#changed();
        return this.state();
      });
    } catch (error) {
      if (this.#closed || error instanceof SynchronicityLifecycleClosedError) {
        return this.state();
      }
      throw error;
    }
  }

  /** Publishes a local folder as a space and scans it, so its files are in the tree at once. */
  async sourceAdd(
    input: SynchronicitySourceAddInput
  ): Promise<SynchronicityMutationResult> {
    await mkdir(input.path, { recursive: true });
    await this.#control.run({
      sourceAdd: { api: false, path: input.path, space: input.space },
    });
    await this.#control.run({ sourceScan: { space: input.space } });
    this.#changed();
    return { status: "done" };
  }

  async sourceRemove(
    input: SynchronicitySourceRemoveInput
  ): Promise<SynchronicityMutationResult> {
    await this.#control.run({ sourceRm: { space: input.space } });
    this.#changed();
    return { status: "done" };
  }

  /**
   * A local copy of a space this node does not publish: a replica with a
   * checkout the node keeps current on disk. An empty path drops it; the
   * files it wrote stay where they are.
   */
  async replicaSet(
    input: SynchronicityReplicaSetInput
  ): Promise<SynchronicityMutationResult> {
    if (!input.checkoutPath) {
      await this.#control.run({ replicaRm: { pinHeld: false, space: input.space } });
      this.#changed();
      return { status: "done" };
    }
    await mkdir(input.checkoutPath, { recursive: true });
    const existing = (await this.#spaces()).find((space) => space.id === input.space);
    await this.#control.run(
      existing?.replica
        ? {
            replicaSet: {
              checkout: input.checkoutPath,
              noBudget: false,
              noCheckout: false,
              space: input.space,
            },
          }
        : {
            replicaAdd: {
              checkout: input.checkoutPath,
              retention: "current",
              space: input.space,
            },
          }
    );
    this.#changed();
    return { status: "done" };
  }

  async replicaSync(
    input: SynchronicityReplicaSyncInput
  ): Promise<SynchronicityReplicaSyncResult> {
    const result = await this.#control.run({ replicaSync: { space: input.space } });
    this.#changed();
    return { ...parseSynchReplicaSync(result.stdout), status: "done" };
  }

  async pin(input: SynchronicityPinInput): Promise<SynchronicityMutationResult> {
    const target = `${input.space}/${input.path}`;
    await this.#control.run(
      input.action === "add" ? { pinAdd: { target } } : { pinRm: { target } }
    );
    return { status: "done" };
  }

  /**
   * Writes the cluster's files for a space this node publishes into its
   * folder: additive, so a path only this node has stays, and a path the
   * cluster disagrees about is left alone unless `replace` says otherwise.
   */
  async adoptTree(
    input: SynchronicityAdoptTreeInput
  ): Promise<SynchronicityAdoptTreeResult> {
    const result = await this.#control.run({
      adoptTree: {
        dryRun: input.dryRun,
        reference: input.space,
        replace: input.replace,
      },
    });
    if (!input.dryRun) this.#changed();
    return { ...parseSynchAdoptTree(result.stdout), status: "done" };
  }

  /** Brings the node down and up again — the way out of an `error` state. */
  async restart(): Promise<SynchronicityState> {
    if (this.#closed) return this.state();
    try {
      return await this.#enqueueLifecycle(async (signal) => {
        if (this.#options.binaryPath) {
          try {
            await this.#stopDaemon(signal);
          } catch (error) {
            if (signal.aborted) throw error;
            // A daemon that was never up has nothing to stop.
          }
        }
        this.#assertLifecycleOpen(signal);
        this.#status = "unavailable";
        this.#reason = undefined;
        await this.#startWithReporting(true, signal);
        this.#assertLifecycleOpen(signal);
        this.#changed();
        return this.state();
      });
    } catch (error) {
      if (this.#closed || error instanceof SynchronicityLifecycleClosedError) {
        return this.state();
      }
      throw error;
    }
  }

  async pickFolder(): Promise<SynchronicityPickFolderResult> {
    const path = await this.#options.pickFolder?.();
    return { path: path ?? "" };
  }

  async setSpaceSettings(
    input: SynchronicitySpaceSettingsInput
  ): Promise<SynchronicityState> {
    return this.#enqueueSync(async () => {
      if (input.syncEnabled !== undefined) {
        const source = (await this.#control.listSpaces()).find(
          (space) => space.id === input.space
        );
        if (!source?.sourcePath)
          throw new Error("Local sync requires a filesystem source.");
        if (source.sourcePaused === undefined) {
          throw new Error(
            "This version of Comma cannot pause local sync. Update Comma and try again."
          );
        }
      }
      const next: DriveSettingsFile = {
        spaces: {
          ...this.#settings.spaces,
          [input.space]: {
            ...this.#settings.spaces[input.space],
            ...(input.syncEnabled === undefined
              ? {}
              : { autoAdopt: input.syncEnabled }),
            ...(input.label === undefined ? {} : { label: input.label }),
          },
        },
      };
      const save = async () => {
        const path = join(this.#options.dataDir, SETTINGS_FILE);
        await writeFile(`${path}.tmp`, `${JSON.stringify(next, null, 2)}\n`);
        await rename(`${path}.tmp`, path);
        this.#settings = next;
      };
      if (input.syncEnabled !== true) await save();
      try {
        if (input.syncEnabled !== undefined) {
          await this.#control.run({
            sourceSetPaused: { space: input.space, paused: !input.syncEnabled },
          });
        }
        if (input.syncEnabled === true) await save();
      } finally {
        this.#changed();
      }
      const state = await this.state();
      if (input.syncEnabled !== undefined) {
        const source = state.spaces.find((space) => space.id === input.space);
        if (
          !source ||
          source.sourcePaused !== !input.syncEnabled ||
          source.autoAdopt !== input.syncEnabled
        ) {
          throw new Error(
            "Local sync settings could not be confirmed. Refresh Drive and retry."
          );
        }
      }
      return state;
    });
  }

  #enqueueSync<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#syncTail.then(operation);
    this.#syncTail = result.catch(() => undefined);
    return result;
  }

  async #loadSettings() {
    try {
      const raw = await readFile(join(this.#options.dataDir, SETTINGS_FILE), "utf8");
      this.#settings = driveSettingsSchema.parse(JSON.parse(raw));
    } catch {
      // No settings yet: the file is written on the first change.
      this.#settings = { spaces: {} };
    }
  }

  async #pins(): Promise<string[]> {
    const result = await this.#control.run({ pinLs: {} });
    return parseSynchPins(result.stdout);
  }

  /** Peer discovery is auxiliary: a failed command never makes Drive unavailable. */
  async #origins(): Promise<string[]> {
    try {
      const result = await this.#control.run({ peerLs: {} });
      const peers = parseSynchPeerOrigins(result.stdout);
      return [...new Set([this.#origin, ...peers])].filter(Boolean);
    } catch (error) {
      this.#options.log?.warn(
        `synchronicity peer discovery failed: ${error instanceof Error ? error.message : String(error)}`
      );
      return this.#origin ? [this.#origin] : [];
    }
  }

  async *#readChunks(
    input: Pick<SynchronicitySaveDownloadInput, "path" | "policy" | "space">
  ): AsyncGenerator<Uint8Array> {
    const reference = {
      path: input.path,
      ...(input.policy ? { policy: input.policy } : {}),
      space: input.space,
    };
    const before = await this.#control.resolve(reference);
    assertReadableFile(before);
    let received = 0;
    for await (const chunk of this.#control.read({ ...reference, start: 0 })) {
      received += chunk.byteLength;
      if (received > before.size) {
        throw new SynchControlError(
          "control Read exceeded the resolved file size",
          "invalid"
        );
      }
      if (chunk.byteLength > 0) yield chunk;
    }
    if (received !== before.size) {
      throw new SynchControlError(
        "control Read ended before the streamed file was complete",
        "invalid"
      );
    }
    await this.#assertUnchanged(reference, before.contentRoot, before.size);
  }

  async #refreshIdentity(force = false) {
    const now = Date.now();
    if (!force && now - this.#identityRefreshedAt < IDENTITY_REFRESH_MS) return;
    const id = await this.#control.run({ id: {} });
    this.#origin = nodeIdSchema.parse({
      origin: firstField(id.stdout, "origin"),
    }).origin;
    this.#domain = domainFrom(id.stdout);
    this.#identityRefreshedAt = now;
  }

  async #start(forceDaemonStart: boolean, signal: AbortSignal) {
    this.#assertLifecycleOpen(signal);
    const binary = this.#options.binaryPath;
    if (!binary || !existsSync(binary)) {
      this.#status = "unavailable";
      this.#reason = binary
        ? `synch binary was not found at ${binary}. Run pnpm --filter @comma/electron build:native:synch.`
        : "synch binary path is not configured.";
      return;
    }
    this.#status = "starting";
    await mkdir(this.#options.dataDir, { recursive: true });
    this.#assertLifecycleOpen(signal);
    await this.#loadSettings();
    this.#assertLifecycleOpen(signal);
    if (!existsSync(join(this.#options.dataDir, "synchronicity.db"))) {
      const initialized = await this.#run(
        this.#binary(),
        ["init", ...this.#dataDirArgs()],
        { signal }
      );
      this.#assertLifecycleOpen(signal);
      if (initialized.code !== 0) {
        throw new Error(
          `synch init exited with ${initialized.code}: ${initialized.stderr.trim() || initialized.stdout.trim()}`
        );
      }
    }
    await this.#startDaemon(forceDaemonStart, signal);
    this.#assertLifecycleOpen(signal);
    await this.#refreshIdentity(true);
    this.#assertLifecycleOpen(signal);
    await this.#ensureDefaultSource();
    this.#assertLifecycleOpen(signal);
    this.#status = "ready";
    this.#reason = undefined;
    this.#options.log?.info(`synchronicity node ready as ${this.#origin}`);
  }

  async #startDaemon(force: boolean, signal: AbortSignal) {
    this.#assertLifecycleOpen(signal);
    if (!force) {
      const status = await this.#run(
        this.#binary(),
        ["daemon", "status", ...this.#dataDirArgs()],
        { signal }
      );
      this.#assertLifecycleOpen(signal);
      if (status.code === 0) return;
    }

    // Control DaemonStop answers before the old process finishes draining its
    // workers and releases the datadir lifecycle lock. Retry only that precise
    // transient; every other launcher failure remains immediate and visible.
    const deadline = Date.now() + DAEMON_START_TIMEOUT_MS;
    for (;;) {
      this.#assertLifecycleOpen(signal);
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error("synch daemon start timed out");
      const started = await this.#runWithDeadline(
        ["daemon", "start", ...this.#dataDirArgs()],
        signal,
        remaining,
        "synch daemon start timed out"
      );
      this.#assertLifecycleOpen(signal);
      if (started.code === 0) return;

      const detail = started.stderr.trim() || started.stdout.trim();
      if (!DAEMON_LIFECYCLE_BUSY.test(detail)) {
        throw new Error(`synch daemon start exited with ${started.code}: ${detail}`);
      }
      if (Date.now() >= deadline) {
        throw new Error(`synch daemon start exited with ${started.code}: ${detail}`);
      }
      await waitForAbortableDelay(
        Math.min(DAEMON_START_RETRY_MS, deadline - Date.now()),
        signal
      );
    }
  }

  /**
   * The install's own published folder: made if absent, added if unpublished,
   * and re-pointed when the node still publishes it under a legacy name the
   * folder has since moved away from.
   */
  async #ensureDefaultSource() {
    const { id, legacyRoots = [] } = this.#options.defaultSpace;
    const sources = await this.#control.run({ sourceLs: { space: "" } });
    const published = publishedSourcePath(sources.stdout, id);
    // Resolve ownership before moving anything: a custom source can itself
    // live inside the legacy folder, which must then remain untouched.
    if (
      published !== undefined &&
      !legacyRoots.some((legacy) => sameSourcePath(published, legacy))
    ) {
      this.#localRoot = published;
      return;
    }
    const root = await prepareDefaultRoot(
      this.#options.defaultSpace,
      this.#options.log
    );
    if (published === undefined || !sameSourcePath(published, root)) {
      if (published !== undefined) await this.#control.run({ sourceRm: { space: id } });
      await this.#control.run({
        sourceAdd: { api: false, path: root, space: id },
      });
      await this.#control.run({ sourceScan: { space: id } });
    }
    this.#localRoot = root;
  }

  async #spaces(): Promise<SynchronicitySpace[]> {
    const spaces = await this.#control.listSpaces();
    return spaces.map((space) => {
      const settings = this.#settings.spaces[space.id] ?? {};
      return {
        autoAdopt:
          !space.sourcePaused &&
          (settings.autoAdopt ?? space.id === this.#options.defaultSpace.id),
        sourcePaused: space.sourcePaused ?? false,
        checkoutPath: space.checkoutPath ?? "",
        heldSize: space.heldBytes ?? 0,
        id: space.id,
        label: settings.label ?? "",
        replica: space.retention !== undefined,
        sourcePath: space.sourcePath ?? "",
        writable: Boolean(space.sourcePath || space.sourceKind === "api"),
      };
    });
  }

  async #assertUnchanged(
    reference: { path: string; policy?: string | undefined; space: string },
    contentRoot: string,
    size: number
  ) {
    const after = await this.#control.resolve(reference);
    if (after.contentRoot !== contentRoot || after.size !== size) {
      throw new SynchControlError(
        "control Read changed content root during transfer",
        "conflict"
      );
    }
  }

  async #stopDaemon(signal: AbortSignal) {
    signal.throwIfAborted();
    try {
      await this.#control.run({ daemonStop: {} });
      signal.throwIfAborted();
      return;
    } catch {
      signal.throwIfAborted();
      const stopped = await this.#runWithDeadline(
        ["daemon", "stop", ...this.#dataDirArgs()],
        signal,
        DAEMON_STOP_TIMEOUT_MS,
        "synch daemon stop timed out"
      );
      const detail = stopped.stderr.trim() || stopped.stdout.trim();
      if (stopped.code !== 0 && !detail.includes("no daemon is running for")) {
        throw new Error(`synch daemon stop exited with ${stopped.code}: ${detail}`);
      }
    }
  }

  #enqueueLifecycle<T>(operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    return this.#enqueueLifecycleTurn(async () => {
      if (this.#closed) throw new SynchronicityLifecycleClosedError();
      const controller = new AbortController();
      this.#activeLifecycle = controller;
      try {
        return await operation(controller.signal);
      } finally {
        if (this.#activeLifecycle === controller) {
          this.#activeLifecycle = undefined;
        }
      }
    });
  }

  #enqueueLifecycleTurn<T>(operation: () => Promise<T>): Promise<T> {
    const turn = this.#lifecycleTail.then(operation);
    this.#lifecycleTail = turn.then(
      () => undefined,
      () => undefined
    );
    return turn;
  }

  #assertLifecycleOpen(signal: AbortSignal) {
    if (this.#closed || signal.aborted) {
      throw new SynchronicityLifecycleClosedError();
    }
  }

  async #runWithDeadline(
    args: string[],
    signal: AbortSignal,
    timeoutMs: number,
    message: string
  ) {
    this.#assertSignalActive(signal);
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(new Error(message)), timeoutMs);
    timer.unref();
    const commandSignal = AbortSignal.any([signal, deadline.signal]);
    try {
      const result = await this.#run(this.#binary(), args, {
        signal: commandSignal,
      });
      if (deadline.signal.aborted) throw abortReason(deadline.signal);
      this.#assertSignalActive(signal);
      return result;
    } catch (error) {
      if (signal.aborted) throw abortReason(signal);
      if (deadline.signal.aborted) throw abortReason(deadline.signal);
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  #assertSignalActive(signal: AbortSignal) {
    if (signal.aborted) throw abortReason(signal);
  }

  #binary() {
    const binary = this.#options.binaryPath;
    if (!binary) throw new Error("synch binary path is not configured.");
    return binary;
  }

  #dataDirArgs() {
    return ["--data-dir", this.#options.dataDir];
  }
}

/** `origin: key:…` from `synch id`. */
function firstField(output: string, field: string) {
  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith(`${field}:`)) return trimmed.slice(field.length + 1).trim();
  }
  return "";
}

/** `named by: cluster.example.com (…)` from `synch id`, empty for a key-named node. */
function domainFrom(output: string) {
  const named = firstField(output, "named by");
  if (!named || named.startsWith("this device key")) return "";
  return named.split(/\s+/)[0] ?? "";
}

function abortReason(signal: AbortSignal) {
  return signal.reason instanceof Error
    ? signal.reason
    : new Error("synch command was cancelled");
}

async function waitForAbortableDelay(timeoutMs: number, signal: AbortSignal) {
  signal.throwIfAborted();
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(done, timeoutMs);
    const abort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      reject(abortReason(signal));
    };
    function done() {
      signal.removeEventListener("abort", abort);
      resolve();
    }
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
}

async function* singleChunk(bytes: Uint8Array) {
  yield bytes;
}

async function* lazyFileChunks(path: string): AsyncIterable<Uint8Array> {
  const stream = createReadStream(path);
  try {
    for await (const chunk of stream) {
      yield chunk as Uint8Array;
    }
  } finally {
    stream.destroy();
  }
}

function assertReadableFile(entry: { contentRoot: string; kind: string }) {
  if (entry.kind !== "file" || !entry.contentRoot) {
    throw new SynchControlError(
      "control Resolve did not select readable file content",
      "invalid"
    );
  }
}
