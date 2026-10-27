import { MaintenanceCapabilityProbe } from "./host-maintenance-protocol";
import { createHash, randomUUID } from "node:crypto";
import { constants, createReadStream, realpathSync } from "node:fs";
import {
  access,
  lstat,
  mkdir,
  open,
  readFile,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import extract from "extract-zip";
import { DatabaseSync } from "node:sqlite";
import { realMainClock, type MainClock } from "../../clock";
import type { ComputeNodeState } from "@comma/native-bridge";
import { getPublishedAssetUrl } from "../../../release-config";
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";

const APP_NAME = "Agent VMM Host.app";
const MAX_ARCHIVE_BYTES = 2 * 1024 ** 3;
const MAX_EXTRACTED_BYTES = 8 * 1024 ** 3;
/** A download that receives no byte for this long is given up; its `.part` file resumes on the next attempt. */
const DOWNLOAD_IDLE_MS = 60_000;
/**
 * Without a caller deadline (Local maintenance), one preparation may take this long in total: waiting for another
 * preparer, downloading, publishing. Automatic continuation passes its own overall deadline instead.
 */
const DEFAULT_PREPARATION_MS = 45 * 60_000;
const PUBLISH_TIMEOUT_MS = 10 * 60_000;
const LOCK_POLL_MS = 250;

/** The Host preflight found too little free disk space. Nothing was installed. */
export class HostPreflightError extends Error {
  constructor(
    readonly requiredBytes: number,
    readonly availableBytes: number
  ) {
    super(
      `Agent VMM Host needs ${Math.ceil(requiredBytes / 1024 ** 3)} GB of free disk space.`
    );
  }
}
export type HostPreparationState = NonNullable<ComputeNodeState["preparation"]>;
export type HostCommand = (
  command: string,
  args: string[],
  stdin?: string,
  timeoutMs?: number,
  options?: { cwd?: string; env?: NodeJS.ProcessEnv }
) => Promise<string>;

export interface HostConfiguration {
  sourcePath?: string;
  downloadUrl: string;
  instance: string;
  directory: string;
  maintenanceDirectory: string;
  appPath: string;
  lifecyclePath: string;
  serviceArgs: string[];
}

export function resolveHostConfiguration(
  flavor: "dev" | "staging" | "prod",
  env: NodeJS.ProcessEnv = process.env,
  home = homedir()
): HostConfiguration {
  const configuredSource =
    flavor === "dev" ? env.COMMA_VMM_SOURCE_PATH?.trim() : undefined;
  let sourcePath = configuredSource ? resolve(configuredSource) : undefined;
  if (sourcePath) {
    try {
      sourcePath = realpathSync(sourcePath);
    } catch {
      /* Report a missing checkout when the user starts the build. */
    }
  }
  // This digest is a local directory key, not an integrity or authority check.
  const sourceKey = sourcePath
    ? createHash("sha256").update(sourcePath).digest("hex").slice(0, 24)
    : "download";
  const instance = "shared";
  const directory = join(
    home,
    "Library",
    "Application Support",
    "Agent VMM Host",
    ...(sourcePath ? ["local", sourceKey] : []),
    "current"
  );
  const appPath = join(directory, APP_NAME);
  return {
    ...(sourcePath ? { sourcePath } : {}),
    downloadUrl:
      env.COMMA_VMM_DOWNLOAD_URL?.trim() || getPublishedAssetUrl(publishedHost.path),
    instance,
    directory,
    maintenanceDirectory: join(
      home,
      "Library",
      "Application Support",
      "Agent VMM Maintenance"
    ),
    appPath,
    lifecyclePath: join(appPath, "Contents", "Helpers", "agent-vmm-lifecycle"),
    serviceArgs: ["--service-type", "agent"],
  };
}

interface PendingHostUpdate {
  sourceApp: string;
  targetReleaseId: string;
  requestId: string;
}

export interface HostPreparationOptions {
  /** Epoch ms after which lock waits, downloads and helper commands give up. */
  deadline?: number;
}

export interface HostPreparation {
  state(): HostPreparationState;
  /** Prepares the Host, then runs its disk preflight (`HostPreflightError`) before any installation. */
  ensure(
    report: (state: HostPreparationState) => void,
    options?: HostPreparationOptions
  ): Promise<void>;
  rebuild(report: (state: HostPreparationState) => void): Promise<void>;
}

export class AgentVMMHostPreparation implements HostPreparation {
  private buildReleaseId?: string;
  private phase: HostPreparationState["phase"] = "idle";
  private failure: string | undefined;
  constructor(
    readonly config: HostConfiguration,
    private readonly run: HostCommand,
    private readonly fetcher: typeof fetch = fetch,
    private readonly clock: MainClock = realMainClock,
    readonly probe = new MaintenanceCapabilityProbe(run)
  ) {}

  state(): HostPreparationState {
    return {
      source: this.config.sourcePath ? "local" : "download",
      location:
        this.config.sourcePath || displayDownloadLocation(this.config.downloadUrl),
      instance: this.config.instance,
      phase: this.phase,
      ...(this.phase === "failed" && this.failure ? { error: this.failure } : {}),
    };
  }

  /** Each phase change starts or ends an attempt; only a failure keeps its error, until the next attempt. */
  private setPhase(
    value: HostPreparationState["phase"],
    report: (state: HostPreparationState) => void,
    error?: unknown
  ) {
    this.phase = value;
    this.failure =
      value === "failed"
        ? (error instanceof Error ? error.message : String(error)).slice(-4096) ||
          undefined
        : undefined;
    report(this.state());
  }

  async ensure(
    report: (state: HostPreparationState) => void,
    options: HostPreparationOptions = {}
  ) {
    const deadline = options.deadline ?? this.clock.now() + DEFAULT_PREPARATION_MS;
    await this.prepare(false, report, deadline);
    try {
      await this.preflight(deadline);
    } catch (error) {
      this.setPhase("failed", report, error);
      throw error;
    }
  }

  rebuild(report: (state: HostPreparationState) => void) {
    if (!this.config.sourcePath)
      throw new Error("Rebuild requires COMMA_VMM_SOURCE_PATH.");
    return this.prepare(true, report, this.clock.now() + DEFAULT_PREPARATION_MS);
  }

  /**
   * The Host's own resource preflight, before a managed installation creates its VM disk. An older Host without the
   * command, or an answer Main cannot read, skips the check: the installation then reports its own failure.
   */
  private async preflight(deadline: number) {
    let value: unknown;
    try {
      value = JSON.parse(
        await this.run(
          this.config.lifecyclePath,
          ["preflight", "--json"],
          undefined,
          this.remaining(deadline, 30_000)
        )
      );
    } catch {
      return;
    }
    const answer = value as {
      ok?: unknown;
      issues?: { code?: unknown; requiredBytes?: unknown; availableBytes?: unknown }[];
    } | null;
    if (answer?.ok !== false || !Array.isArray(answer.issues)) return;
    const disk = answer.issues.find((issue) => issue?.code === "insufficient_disk");
    if (
      disk &&
      Number.isSafeInteger(disk.requiredBytes) &&
      Number.isSafeInteger(disk.availableBytes)
    )
      throw new HostPreflightError(
        disk.requiredBytes as number,
        disk.availableBytes as number
      );
  }

  /** The command timeout: its own bound, or less when the overall deadline is nearer. */
  private remaining(deadline: number, bound: number) {
    const left = deadline - this.clock.now();
    if (left <= 0) throw new Error("Host preparation exceeded its deadline.");
    return Math.min(bound, left);
  }

  /** Prepare a verified helper outside both the installed application and VM data.
   * Maintenance must also work when the installed helper is old, broken or absent.
   */
  async stageMaintenance(
    requestId: string,
    report: (state: HostPreparationState) => void,
    artifact = publishedHost,
    execute?: (bundle: {
      sourceApp: string;
      targetReleaseId: string;
      artifactSha256?: string;
      artifactSize?: number;
    }) => Promise<void>
  ): Promise<{
    sourceApp: string;
    targetReleaseId: string;
    artifactSha256?: string;
    artifactSize?: number;
  }> {
    if (!/^[a-f0-9-]{36}$/.test(requestId))
      throw new Error("Invalid maintenance request.");
    const phase = (value: HostPreparationState["phase"]) =>
      this.setPhase(value, report);
    await mkdir(this.config.directory, { recursive: true, mode: 0o700 });
    let lock: DatabaseSync | undefined;
    try {
      lock = await this.acquireLock(this.clock.now() + DEFAULT_PREPARATION_MS);
      const sourceDirectory = join(this.config.directory, `.maintenance-${requestId}`);
      if (
        (await pathExists(sourceDirectory)) &&
        (await lstat(sourceDirectory)).isSymbolicLink()
      )
        throw new Error("Maintenance bundle directory cannot be a symbolic link.");
      const sourceApp = join(sourceDirectory, APP_NAME);
      const prepared = join(this.config.directory, ".prepared");
      // One signature check per bundle before it is used: a retained bundle is checked
      // when it is reused, a new bundle when it lands.
      let version: { release_id: string } | undefined;
      if (await pathExists(sourceApp)) {
        try {
          await this.verifyBundle(sourceApp);
          version = await this.bundleVersion(sourceApp);
        } catch {
          version = undefined;
          await rm(sourceApp, { recursive: true, force: true });
        }
      }
      if (!version) {
        await mkdir(sourceDirectory, { recursive: true, mode: 0o700 });
        await mkdir(prepared, { recursive: true, mode: 0o700 });
        const staged = this.config.sourcePath
          ? await this.build(prepared, phase)
          : await this.download(
              prepared,
              phase,
              this.clock.now() + DEFAULT_PREPARATION_MS,
              artifact
            );
        await this.verifyBundle(staged);
        await rename(staged, sourceApp);
        version = await this.bundleVersion(sourceApp);
      }
      // The download was checked against the pinned digest when it landed; its release is the bundle's own.
      const targetReleaseId = this.config.sourcePath
        ? (this.buildReleaseId ?? version.release_id)
        : artifact.release_id;
      const digest = this.config.sourcePath
        ? {}
        : { artifactSha256: artifact.sha256, artifactSize: artifact.size };
      phase("ready");
      const bundle = { sourceApp, targetReleaseId, ...digest };
      // Keep Comma's preparation lock through native maintenance. Native owns
      // the cross-application lock and policy at the actual mutation boundary.
      await execute?.(bundle);
      return bundle;
    } catch (error) {
      this.setPhase("failed", report, error);
      throw error;
    } finally {
      lock?.close();
    }
  }

  private async bundleVersion(appPath: string): Promise<{ release_id: string }> {
    return JSON.parse(
      await this.run(join(appPath, "Contents", "Helpers", "agent-vmm-lifecycle"), [
        "version",
        "--json",
      ])
    );
  }

  /** SQLite releases the cross-process lock on process exit, so no stale lock deletion is needed.
   * A second preparer waits for the current one, up to the caller's overall deadline. One waiter per process
   * polls once per {@link LOCK_POLL_MS}; it opens no network connection while it waits.
   */
  private async acquireLock(deadline: number) {
    for (;;) {
      const lock = new DatabaseSync(join(this.config.directory, ".prepare.sqlite"));
      try {
        lock.exec("BEGIN IMMEDIATE");
        return lock;
      } catch (error) {
        lock.close();
        if (!isBusy(error)) throw error;
        if (this.clock.now() >= deadline)
          throw new Error(
            "Another Comma process is still preparing this Host. Try again later.",
            { cause: error }
          );
      }
      await new Promise<void>((wake) => this.clock.setTimer(LOCK_POLL_MS, wake));
    }
  }

  private async verifyBundle(appPath: string) {
    if ((await lstat(appPath)).isSymbolicLink())
      throw new Error("Host bundle cannot be a symbolic link.");
    await this.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath]);
    for (const executable of [
      "Helpers/agent-vmm-lifecycle",
      "Helpers/agent-vmm-service-executor",
      "Helpers/agent-vmm",
      "MacOS/agent-vmm-host",
    ])
      await access(join(appPath, "Contents", executable), constants.X_OK);
  }

  private async prepare(
    rebuild: boolean,
    report: (state: HostPreparationState) => void,
    deadline: number
  ) {
    const phase = (value: HostPreparationState["phase"]) =>
      this.setPhase(value, report);
    phase("checking");
    await mkdir(this.config.directory, { recursive: true, mode: 0o700 });
    let lock: DatabaseSync;
    try {
      lock = await this.acquireLock(deadline);
    } catch (error) {
      this.setPhase("failed", report, error);
      throw error;
    }
    try {
      await this.assertSetupAllowed();
      const pendingFile = join(this.config.directory, ".pending-update.json");
      if (await pathExists(pendingFile)) {
        phase("installing");
        await this.applyUpdate(JSON.parse(await readFile(pendingFile, "utf8")));
        await rm(pendingFile);
        phase("ready");
        return;
      }
      const installed = await pathExists(this.config.appPath);
      if (installed) {
        if ((await lstat(this.config.appPath)).isSymbolicLink())
          throw new Error("Host installation cannot be a symbolic link.");
        await access(this.config.lifecyclePath, constants.X_OK);
        if (!rebuild) {
          await this.activateSource();
          phase("ready");
          return;
        }
      }
      const preparedDirectory = join(this.config.directory, ".prepared");
      await mkdir(preparedDirectory, { recursive: true, mode: 0o700 });
      const stagedApp = this.config.sourcePath
        ? await this.build(preparedDirectory, phase)
        : await this.download(preparedDirectory, phase, deadline);
      phase("installing");
      try {
        await this.verifyBundle(stagedApp);
      } catch (error) {
        if (!this.config.sourcePath)
          await rm(join(preparedDirectory, "download.json"), { force: true });
        throw error;
      }
      if (!installed) {
        await this.assertSetupAllowed();
        if (this.config.sourcePath) await rename(stagedApp, this.config.appPath);
        else
          await this.run(
            join(stagedApp, "Contents", "Helpers", "agent-vmm-lifecycle"),
            ["publish-host", "--source-app", stagedApp, ...this.config.serviceArgs],
            undefined,
            this.remaining(deadline, PUBLISH_TIMEOUT_MS)
          );
        await this.activateSource();
      } else {
        const requestId = `comma-update-${randomUUID()}`;
        const stagedSibling = join(
          this.config.directory,
          `.Agent VMM Host.${requestId}.app`
        );
        await rename(stagedApp, stagedSibling);
        const pending: PendingHostUpdate = {
          sourceApp: stagedSibling,
          targetReleaseId: this.buildReleaseId ?? publishedHost.release_id,
          requestId,
        };
        const record = await open(`${pendingFile}.tmp`, "w", 0o600);
        try {
          await record.writeFile(JSON.stringify(pending));
        } finally {
          await record.close();
        }
        await rename(`${pendingFile}.tmp`, pendingFile);
        await this.applyUpdate(pending);
        await rm(pendingFile);
      }
      phase("ready");
    } catch (error) {
      const failedPhase = this.phase;
      this.setPhase("failed", report, error);
      throw new Error(
        `${failedPhase}: ${error instanceof Error ? error.message : String(error)}`,
        { cause: error }
      );
    } finally {
      lock.close();
    }
  }

  private async assertSetupAllowed() {
    if (this.config.sourcePath) return;
    let policy: unknown;
    try {
      policy = JSON.parse(
        await readFile(join(this.config.maintenanceDirectory, "state.json"), "utf8")
      );
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw new Error(
        "Local Host maintenance policy is unreadable; automatic setup is paused.",
        { cause: error }
      );
    }
    // Read only the fields this version knows; a newer owner may add others. Main never writes this file.
    if (
      !policy ||
      typeof policy !== "object" ||
      !("version" in policy) ||
      !Number.isSafeInteger(policy.version) ||
      ("activeRequest" in policy && policy.activeRequest) ||
      ("uninstalled" in policy && policy.uninstalled === true)
    )
      throw new Error(
        "Continue local Host maintenance or explicitly reinstall Agent VMM before automatic setup."
      );
  }

  private async activateSource() {
    if (this.config.sourcePath) {
      await this.probe.assert(this.config.lifecyclePath, this.config.serviceArgs);
      // Managed enrollment reuses any healthy shared Host. Repair first so an
      // explicit source selection also selects the running service binary.
      await this.run(
        this.config.lifecyclePath,
        ["repair", ...this.config.serviceArgs],
        undefined,
        10 * 60_000
      );
    }
  }

  private async applyUpdate(pending: PendingHostUpdate) {
    if (
      typeof pending.sourceApp !== "string" ||
      dirname(pending.sourceApp) !== this.config.directory ||
      !basename(pending.sourceApp).startsWith(".Agent VMM Host.") ||
      !pending.sourceApp.endsWith(".app") ||
      typeof pending.targetReleaseId !== "string" ||
      !pending.targetReleaseId ||
      typeof pending.requestId !== "string" ||
      !pending.requestId
    ) {
      throw new Error("The pending Host update record is invalid.");
    }
    await this.probe.assert(this.config.lifecyclePath, this.config.serviceArgs);
    await this.run(
      this.config.lifecyclePath,
      [
        "update",
        ...this.config.serviceArgs,
        "--source-app",
        pending.sourceApp,
        "--target-release-id",
        pending.targetReleaseId,
        "--request-id",
        pending.requestId,
      ],
      undefined,
      10 * 60_000
    );
  }

  private async download(
    directory: string,
    phase: (phase: HostPreparationState["phase"]) => void,
    deadline: number,
    artifact?: typeof publishedHost
  ) {
    const selected = artifact ?? publishedHost;
    const url = new URL(
      artifact ? getPublishedAssetUrl(artifact.path) : this.config.downloadUrl
    );
    if (url.protocol !== "https:" || url.username || url.password) {
      throw new Error(
        "COMMA_VMM_DOWNLOAD_URL must be a public HTTPS URL without credentials."
      );
    }
    const archive = join(directory, "Host.zip");
    const metadata = join(directory, "download.json");
    const pinned = url.href === getPublishedAssetUrl(selected.path);
    let cached = false;
    try {
      // The archive was checked against the pin when it landed; the record names that pin.
      const record = JSON.parse(await readFile(metadata, "utf8"));
      cached =
        record.url === url.href &&
        (!pinned ||
          (record.sha256 === selected.sha256 && record.size === selected.size)) &&
        (await pathExists(archive));
    } catch {
      /* Download only after an explicit action. */
    }
    if (!cached) {
      phase("downloading");
      const { sha256, bytes } = await this.downloadPart(archive, url, deadline);
      if (pinned && (bytes !== selected.size || sha256 !== selected.sha256)) {
        // A wrong archive must not be resumed again.
        await rm(`${archive}.part`, { force: true });
        await rm(`${archive}.part.json`, { force: true });
        throw new Error(
          "Host download does not match the selected published artifact. Retry the download."
        );
      }
      await rename(`${archive}.part`, archive);
      await rm(`${archive}.part.json`, { force: true });
      const record = await open(metadata, "w", 0o600);
      try {
        await record.writeFile(JSON.stringify({ url: url.href, sha256, size: bytes }));
      } finally {
        await record.close();
      }
    }
    phase("extracting");
    const extracted = join(directory, "unpacked");
    // Only this preparer's temporary extraction output is disposable.
    await rm(extracted, { recursive: true, force: true });
    await mkdir(extracted, { recursive: true, mode: 0o700 });
    let expanded = 0;
    let entries = 0;
    try {
      await extract(archive, {
        dir: extracted,
        onEntry(entry) {
          expanded += entry.uncompressedSize;
          entries += 1;
          const mode = (entry.externalFileAttributes >>> 16) & 0o170000;
          if (
            entries > 100_000 ||
            expanded > MAX_EXTRACTED_BYTES ||
            mode === 0o120000
          ) {
            throw new Error(
              "Host archive contains an unsupported link or exceeds 8 GiB."
            );
          }
        },
      });
    } catch (error) {
      await rm(metadata, { force: true });
      throw error;
    }
    return join(extracted, APP_NAME);
  }

  /**
   * Downloads `url` into `<archive>.part`. A `.part` file left by an interrupted attempt of the same URL resumes with
   * an HTTP Range request (and `If-Range` with the first answer's validator); a server that answers the whole file
   * restarts it. The attempt stops after {@link DOWNLOAD_IDLE_MS} without a byte, or at the overall deadline.
   */
  private async downloadPart(archive: string, url: URL, deadline: number) {
    const partial = `${archive}.part`;
    const partRecord = `${archive}.part.json`;
    let offset = 0;
    let validator: string | undefined;
    try {
      const record = JSON.parse(await readFile(partRecord, "utf8")) as {
        url?: unknown;
        validator?: unknown;
      };
      if (record.url === url.href && (await pathExists(partial))) {
        offset = (await stat(partial)).size;
        validator = typeof record.validator === "string" ? record.validator : undefined;
      }
    } catch {
      /* No resumable part. */
    }
    const controller = new AbortController();
    const abort = (message: string) =>
      controller.abort(new DOMException(message, "TimeoutError"));
    const stopDeadline = this.clock.setTimer(
      Math.max(0, deadline - this.clock.now()),
      () => abort("Host download exceeded its deadline.")
    );
    let stopIdle = this.clock.setTimer(DOWNLOAD_IDLE_MS, () =>
      abort("Host download stopped receiving data.")
    );
    const touch = () => {
      stopIdle();
      stopIdle = this.clock.setTimer(DOWNLOAD_IDLE_MS, () =>
        abort("Host download stopped receiving data.")
      );
    };
    try {
      const headers: Record<string, string> =
        offset > 0
          ? {
              range: `bytes=${offset}-`,
              ...(validator ? { "if-range": validator } : {}),
            }
          : {};
      const response = await this.fetchArchive(url, controller.signal, headers);
      if (offset > 0 && response.status === 206) {
        const range = /^bytes (\d+)-\d+\/(\d+|\*)$/.exec(
          response.headers.get("content-range") ?? ""
        );
        if (Number(range?.[1]) !== offset) {
          await response.body?.cancel();
          offset = 0;
          await rm(partial, { force: true });
          await rm(partRecord, { force: true });
          throw new Error(
            "Host download resumed at another offset. Retry the download."
          );
        }
      } else {
        if (offset > 0 && response.status === 416) {
          // The kept part no longer fits the file: start over on the next attempt.
          await rm(partial, { force: true });
          await rm(partRecord, { force: true });
        }
        if (!response.ok || !response.body)
          throw new Error(`Host download failed (HTTP ${response.status}).`);
        offset = 0;
      }
      if (!response.body)
        throw new Error(`Host download failed (HTTP ${response.status}).`);
      if (new URL(response.url || url).protocol !== "https:")
        throw new Error("Host download redirected outside HTTPS.");
      const nextValidator =
        response.headers.get("etag") ??
        response.headers.get("last-modified") ??
        undefined;
      if (offset === 0) {
        const record = await open(partRecord, "w", 0o600);
        try {
          await record.writeFile(
            JSON.stringify({
              url: url.href,
              ...(nextValidator ? { validator: nextValidator } : {}),
            })
          );
        } finally {
          await record.close();
        }
      }
      const digest = createHash("sha256");
      // The digest covers the whole archive, so a resumed part hashes its kept bytes first.
      if (offset > 0)
        for await (const chunk of createReadStream(partial, { end: offset - 1 }))
          digest.update(chunk as Buffer);
      let bytes = offset;
      const file = await open(partial, offset > 0 ? "a" : "w", 0o600);
      try {
        await pipeline(
          Readable.fromWeb(response.body as Parameters<typeof Readable.fromWeb>[0]),
          new Transform({
            transform(chunk: Buffer, _encoding, callback) {
              touch();
              bytes += chunk.length;
              if (bytes > MAX_ARCHIVE_BYTES) {
                callback(new Error("Host archive exceeds 2 GiB."));
                return;
              }
              digest.update(chunk);
              callback(null, chunk);
            },
          }),
          file.createWriteStream()
        );
      } finally {
        await file.close();
      }
      return { sha256: digest.digest("hex"), bytes };
    } catch (error) {
      if (controller.signal.aborted) throw controller.signal.reason as Error;
      throw error;
    } finally {
      stopIdle();
      stopDeadline();
    }
  }

  private async fetchArchive(
    initialUrl: URL,
    signal: AbortSignal,
    headers: Record<string, string>
  ) {
    let url = initialUrl;
    for (let redirects = 0; redirects <= 5; redirects += 1) {
      if (url.protocol !== "https:" || url.username || url.password) {
        throw new Error(
          "Host download requires HTTPS without URL credentials, including redirects."
        );
      }
      const response = await this.fetcher(url, { signal, redirect: "manual", headers });
      if (response.status < 300 || response.status >= 400) return response;
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (!location) throw new Error("Host download redirect has no location.");
      url = new URL(location, url);
    }
    throw new Error("Host download exceeded five redirects.");
  }

  private async build(
    directory: string,
    phase: (phase: HostPreparationState["phase"]) => void
  ) {
    phase("building");
    const source = this.config.sourcePath!;
    const guest = join(directory, "guest");
    // The source's Guest build runs `docker buildx` for linux/arm64 itself and reuses its build cache.
    await this.run(
      join(source, "build", "guest", "build.sh"),
      [guest, "development", "runtime"],
      undefined,
      60 * 60_000,
      { cwd: source }
    );
    this.buildReleaseId = `comma-dev-${randomUUID()}`;
    await this.run("make", ["headless-release"], undefined, 60 * 60_000, {
      cwd: source,
      env: {
        ...process.env,
        OUTPUT_DIRECTORY: directory,
        AGENT_VMM_GUEST_BUNDLE: guest,
        AGENT_VMM_PACKAGE_PHASE: "all",
        CODE_SIGN_IDENTITY: "-",
        AGENT_VMM_RELEASE_ID: this.buildReleaseId,
      },
    });
    return join(directory, APP_NAME);
  }
}

async function pathExists(path: string) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function displayDownloadLocation(value: string) {
  try {
    const url = new URL(value);
    return `${url.origin}${url.pathname}`;
  } catch {
    return "Invalid download URL";
  }
}

function isBusy(error: unknown) {
  const code = (error as { errcode?: unknown; code?: unknown } | null)?.errcode;
  return code === 5 || /database is locked|SQLITE_BUSY/i.test(String(error));
}
