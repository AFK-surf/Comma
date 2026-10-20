import { assertMaintenanceCapable } from "./host-maintenance-protocol";
import { createHash, randomUUID } from "node:crypto";
import { constants, realpathSync } from "node:fs";
import { access, lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import extract from "extract-zip";
import { DatabaseSync } from "node:sqlite";
import { clockTimeoutSignal, realMainClock, type MainClock } from "../../clock";
import type { ComputeNodeState } from "@comma/native-bridge";
import { getPublishedAssetUrl } from "../../../release-config";
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";

const APP_NAME = "Agent VMM Host.app";
const MAX_ARCHIVE_BYTES = 2 * 1024 ** 3;
const MAX_EXTRACTED_BYTES = 8 * 1024 ** 3;
const DOWNLOAD_TIMEOUT_MS = 15 * 60_000;
const LOCK_WAIT_MS = DOWNLOAD_TIMEOUT_MS;
const LOCK_POLL_MS = 250;
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

export interface HostPreparation {
  state(): HostPreparationState;
  ensure(report: (state: HostPreparationState) => void): Promise<void>;
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
    private readonly clock: MainClock = realMainClock
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

  ensure(report: (state: HostPreparationState) => void) {
    return this.prepare(false, report);
  }

  rebuild(report: (state: HostPreparationState) => void) {
    if (!this.config.sourcePath)
      throw new Error("Rebuild requires COMMA_VMM_SOURCE_PATH.");
    return this.prepare(true, report);
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
      lock = await this.acquireLock();
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
          if (!this.config.sourcePath && version.release_id !== artifact.release_id)
            throw new Error("Cached maintenance bundle has a different release.");
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
          : await this.download(prepared, phase, artifact);
        await this.verifyBundle(staged);
        await rename(staged, sourceApp);
        version = await this.bundleVersion(sourceApp);
      }
      const targetReleaseId = this.config.sourcePath
        ? (this.buildReleaseId ?? version.release_id)
        : artifact.release_id;
      if (version.release_id !== targetReleaseId)
        throw new Error("Host bundle release does not match the selected artifact.");
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
   * A second preparer waits for the current one, up to the download bound. One waiter per process
   * polls once per {@link LOCK_POLL_MS}; it opens no network connection while it waits.
   */
  private async acquireLock() {
    const deadline = this.clock.now() + LOCK_WAIT_MS;
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
    report: (state: HostPreparationState) => void
  ) {
    const phase = (value: HostPreparationState["phase"]) =>
      this.setPhase(value, report);
    phase("checking");
    await mkdir(this.config.directory, { recursive: true, mode: 0o700 });
    let lock: DatabaseSync;
    try {
      lock = await this.acquireLock();
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
        : await this.download(preparedDirectory, phase);
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
            10 * 60_000
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
    if (
      !policy ||
      typeof policy !== "object" ||
      !("version" in policy) ||
      policy.version !== 1 ||
      !("uninstalled" in policy) ||
      typeof policy.uninstalled !== "boolean" ||
      ("activeRequest" in policy && policy.activeRequest) ||
      policy.uninstalled
    )
      throw new Error(
        "Continue local Host maintenance or explicitly reinstall Agent VMM before automatic setup."
      );
  }

  private async activateSource() {
    if (this.config.sourcePath) {
      await assertMaintenanceCapable(
        this.config.lifecyclePath,
        this.run,
        this.config.serviceArgs
      );
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
    await assertMaintenanceCapable(
      this.config.lifecyclePath,
      this.run,
      this.config.serviceArgs
    );
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
      const partial = `${archive}.part`;
      const response = await this.fetchArchive(url);
      if (!response.ok || !response.body)
        throw new Error(`Host download failed (HTTP ${response.status}).`);
      if (new URL(response.url || url).protocol !== "https:")
        throw new Error("Host download redirected outside HTTPS.");
      const digest = createHash("sha256");
      let bytes = 0;
      const file = await open(partial, "w", 0o600);
      try {
        await pipeline(
          Readable.fromWeb(response.body as Parameters<typeof Readable.fromWeb>[0]),
          new Transform({
            transform(chunk: Buffer, _encoding, callback) {
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
      const sha256 = digest.digest("hex");
      if (pinned && (bytes !== selected.size || sha256 !== selected.sha256)) {
        throw new Error(
          "Host download does not match the selected published artifact. Retry the download."
        );
      }
      await rename(partial, archive);
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

  private async fetchArchive(initialUrl: URL) {
    let url = initialUrl;
    const signal = clockTimeoutSignal(this.clock, DOWNLOAD_TIMEOUT_MS);
    for (let redirects = 0; redirects <= 5; redirects += 1) {
      if (url.protocol !== "https:" || url.username || url.password) {
        throw new Error(
          "Host download requires HTTPS without URL credentials, including redirects."
        );
      }
      const response = await this.fetcher(url, { signal, redirect: "manual" });
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
    // The source owner builds Guest on Linux arm64 and Host on macOS. Existing
    // source scripts report missing Docker/toolchain prerequisites directly.
    await this.run(
      "docker",
      [
        "run",
        "--rm",
        "--platform",
        "linux/arm64",
        "--privileged",
        "--mount",
        `type=bind,source=${source},target=/source`,
        "--mount",
        `type=bind,source=${directory},target=/output`,
        "-w",
        "/source",
        "alpine:latest",
        "sh",
        "-lc",
        "apk add --no-cache bash bzip2 coreutils cpio curl file findutils git go grep jq squashfs-tools tar xz && git config --global --add safe.directory /source && build/guest/build.sh /output/guest development runtime",
      ],
      undefined,
      60 * 60_000
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
