// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 9967fe35be) station/src/screens/linux-tools.ts as it is there.
//
// Programs for the Linux X11 desktop. Prefer the machine's pair; on Debian-family systems the station can prepare
// its own pair without installing packages into the operating system or requiring an administrator.
import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { mkdir, mkdtemp, readdir, rename, rm, writeFile } from "node:fs/promises";
import { delimiter, isAbsolute, join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/// Resolve only executables, without invoking a shell or consulting a different user's environment.
export function executable(name: string, env: NodeJS.ProcessEnv): string | null {
  const paths = isAbsolute(name) || name.includes("/") ? [name] : (env.PATH ?? "").split(delimiter).filter(Boolean).map((dir) => join(dir, name));
  return paths.find((path) => {
    try { accessSync(path, constants.X_OK); return true; } catch { return false; }
  }) ?? null;
}

export type LinuxToolPair = { ffmpeg: string; xdotool: string; env: NodeJS.ProcessEnv };

function pairAt(root: string, env: NodeJS.ProcessEnv): LinuxToolPair | null {
  const ffmpeg = executable(join(root, "usr/bin/ffmpeg"), env);
  const xdotool = executable(join(root, "usr/bin/xdotool"), env);
  const arch = process.arch === "x64" ? "x86_64-linux-gnu" : process.arch === "arm64" ? "aarch64-linux-gnu" : null;
  if (!ffmpeg || !xdotool || !arch) return null;
  const libraries = [join(root, "usr/lib", arch), join(root, "lib", arch), join(root, "usr/lib"), join(root, "lib"), env.LD_LIBRARY_PATH].filter(Boolean).join(delimiter);
  return { ffmpeg, xdotool, env: { ...env, LD_LIBRARY_PATH: libraries } };
}

/// Programs and their dependencies extracted under the station's data directory from the machine's APT repositories.
/// APT verifies its repositories' package hashes; dpkg-deb only unpacks the archives, never runs maintainer scripts.
export class LinuxScreenTools {
  readonly #dir: string;
  #preparing: Promise<void> | null = null;
  #abort: AbortController | null = null;
  #closed = false;

  constructor(data: string) { this.#dir = join(data, "screen-tools", "apt"); }

  /// The pair prepared here, with its libraries searched only by its own child processes.
  prepared(env: NodeJS.ProcessEnv): LinuxToolPair | null {
    try { accessSync(join(this.#dir, "ready"), constants.R_OK); } catch { return null; }
    return pairAt(join(this.#dir, "root"), env);
  }

  /// Whether this machine has the Debian package tools and an architecture the station ships for.
  canPrepare(env: NodeJS.ProcessEnv): boolean {
    return (process.arch === "x64" || process.arch === "arm64") && !!executable("apt-get", env) && !!executable("dpkg-deb", env);
  }

  /// Concurrent requests in one station share the download; an interrupted or failed preparation can be tried again.
  prepare(env: NodeJS.ProcessEnv): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("screen tools closed"));
    if (this.prepared(env)) return Promise.resolve();
    if (!this.#preparing) {
      const abort = new AbortController();
      this.#abort = abort;
      this.#preparing = this.#install(env, abort.signal).finally(() => { this.#preparing = null; this.#abort = null; });
    }
    return this.#preparing;
  }

  close(): void { this.#closed = true; this.#abort?.abort(); }

  async #install(env: NodeJS.ProcessEnv, signal: AbortSignal): Promise<void> {
    const apt = executable("apt-get", env), dpkg = executable("dpkg-deb", env);
    if (!apt || !dpkg || !this.canPrepare(env)) throw new Error("APT package tools are unavailable");
    const parent = join(this.#dir, "..");
    await mkdir(parent, { recursive: true, mode: 0o700 });
    // A station stopped meanwhile starts no download: a killed apt-get can leave a child that writes into the stage
    // while it is removed.
    signal.throwIfAborted();
    const stage = await mkdtemp(join(parent, ".apt-"));
    const archives = join(stage, "archives"), root = join(stage, "root");
    try {
      await mkdir(join(archives, "partial"), { recursive: true, mode: 0o700 });
      // This is read-only with respect to the system's package database. --reinstall downloads both commands even if
      // the database says one is already installed; the private cache and no-locking let it run as the station user.
      await run(apt, ["--download-only", "--assume-yes", "--reinstall", "--no-remove", "--no-install-recommends",
        "-o", "Debug::NoLocking=1", "-o", `Dir::Cache::archives=${archives}`,
        "-o", "Dir::Cache::pkgcache=", "-o", "Dir::Cache::srcpkgcache=", "install", "ffmpeg", "xdotool"],
        { env: { ...env, DEBIAN_FRONTEND: "noninteractive" }, signal, timeout: 180_000, maxBuffer: 4 * 1024 * 1024 });
      const packages = (await readdir(archives)).filter((f) => f.endsWith(".deb")).sort();
      if (!packages.length) throw new Error("APT returned no packages");
      await mkdir(root, { mode: 0o700 });
      for (const file of packages) await run(dpkg, ["--extract", join(archives, file), root], { env, signal, timeout: 30_000 });
      const pair = pairAt(root, env);
      if (!pair) throw new Error("APT packages lack the screen programs");
      const [devices] = await Promise.all([
        run(pair.ffmpeg, ["-hide_banner", "-devices"], { env: pair.env, signal, timeout: 30_000 }),
        run(pair.xdotool, ["--version"], { env: pair.env, signal, timeout: 30_000 }),
      ]);
      if (!/\bD\s+x11grab\b/.test(devices.stdout)) throw new Error("FFmpeg does not support X11 capture");
      await rm(archives, { recursive: true, force: true });
      await writeFile(join(stage, "ready"), "\n", { mode: 0o600 });
      signal.throwIfAborted();
      // Do not replace a pair another station process finished preparing during a handover.
      try { await rename(stage, this.#dir); }
      catch (error) { if (!this.prepared(env)) throw error; }
    } finally {
      await rm(stage, { recursive: true, force: true });
    }
  }
}
