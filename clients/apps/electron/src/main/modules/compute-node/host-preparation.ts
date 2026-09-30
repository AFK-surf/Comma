import { createHash, randomUUID } from "node:crypto";
import { constants, realpathSync } from "node:fs";
import { access, lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import extract from "extract-zip";
import { DatabaseSync } from "node:sqlite";
import type { ComputeNodeState } from "@comma/native-bridge";
import { getPublishedAssetUrl } from "../../../release-config";
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";

const APP_NAME = "Agent VMM Host.app";
const MAX_ARCHIVE_BYTES = 2 * 1024 ** 3;
const MAX_EXTRACTED_BYTES = 8 * 1024 ** 3;
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
  constructor(
    readonly config: HostConfiguration,
    private readonly run: HostCommand,
    private readonly fetcher: typeof fetch = fetch
  ) {}

  state(): HostPreparationState {
    return {
      source: this.config.sourcePath ? "local" : "download",
      location:
        this.config.sourcePath || displayDownloadLocation(this.config.downloadUrl),
      instance: this.config.instance,
      phase: this.phase,
    };
  }

  ensure(report: (state: HostPreparationState) => void) {
    return this.prepare(false, report);
  }

  rebuild(report: (state: HostPreparationState) => void) {
    if (!this.config.sourcePath)
      throw new Error("Rebuild requires COMMA_VMM_SOURCE_PATH.");
    return this.prepare(true, report);
  }

  private async prepare(
    rebuild: boolean,
    report: (state: HostPreparationState) => void
  ) {
    const phase = (value: HostPreparationState["phase"]) => {
      this.phase = value;
      report(this.state());
    };
    phase("checking");
    await mkdir(this.config.directory, { recursive: true, mode: 0o700 });
    // SQLite releases the cross-process lock on process exit. No timer, stale
    // lock deletion, or automatic retry is needed after an interrupted download.
    const lock = new DatabaseSync(join(this.config.directory, ".prepare.sqlite"));
    try {
      lock.exec("BEGIN IMMEDIATE");
    } catch {
      lock.close();
      phase("failed");
      throw new Error(
        "Another Comma process is preparing this Host. Retry after it finishes."
      );
    }
    try {
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
      const stagedHelper = join(
        stagedApp,
        "Contents",
        "Helpers",
        "agent-vmm-lifecycle"
      );
      try {
        await this.run("/usr/bin/codesign", [
          "--verify",
          "--deep",
          "--strict",
          stagedApp,
        ]);
        for (const executable of [
          stagedHelper,
          join(stagedApp, "Contents", "MacOS", "agent-vmm-host"),
          join(stagedApp, "Contents", "Helpers", "agent-vmm"),
          join(stagedApp, "Contents", "Helpers", "agent-vmm-service-executor"),
        ]) {
          await access(executable, constants.X_OK);
        }
      } catch (error) {
        if (!this.config.sourcePath)
          await rm(join(preparedDirectory, "download.json"), { force: true });
        throw error;
      }
      if (!installed) {
        await rename(stagedApp, this.config.appPath);
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
          targetReleaseId: this.buildReleaseId!,
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
      phase("failed");
      throw new Error(
        `${failedPhase}: ${error instanceof Error ? error.message : String(error)}`,
        { cause: error }
      );
    } finally {
      lock.close();
    }
  }

  private async activateSource() {
    if (this.config.sourcePath) {
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
    phase: (phase: HostPreparationState["phase"]) => void
  ) {
    const url = new URL(this.config.downloadUrl);
    if (url.protocol !== "https:" || url.username || url.password) {
      throw new Error(
        "COMMA_VMM_DOWNLOAD_URL must be a public HTTPS URL without credentials."
      );
    }
    const archive = join(directory, "Host.zip");
    const metadata = join(directory, "download.json");
    let cached = false;
    try {
      cached =
        JSON.parse(await readFile(metadata, "utf8")).url === url.href &&
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
      if (
        url.href === getPublishedAssetUrl(publishedHost.path) &&
        (bytes !== publishedHost.size || digest.digest("hex") !== publishedHost.sha256)
      ) {
        throw new Error(
          "Host download does not match the selected published artifact. Retry the download."
        );
      }
      await rename(partial, archive);
      const record = await open(metadata, "w", 0o600);
      try {
        await record.writeFile(JSON.stringify({ url: url.href }));
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
    const signal = AbortSignal.timeout(15 * 60_000);
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
