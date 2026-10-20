// Workspace file helpers for automatic cleanup of archived sessions (the Rust station's footprint.rs).
import { execFile } from "node:child_process";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { lstat, readdir } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fileName, samePath, segments, within } from "../ops/paths.ts";

/// Path::starts_with: `path` is `dir` or under it.
export { within };

const canonical = (path: string): string | null => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

/// Where a session's own directory is: the one its workspace is in when the station made it (sessions/…/workspace),
/// else none (a workspace that is a person's project is not the station's to measure or clean).
export function roomOf(dataDir: string, workspace: string): string | null {
  const sessions = canonical(join(dataDir, "sessions"));
  if (sessions === null) return null;
  let path = canonical(workspace);
  if (path === null) {
    if (fileName(workspace) !== "workspace") return null;
    const parent = canonical(dirname(workspace));
    if (parent === null) return null;
    path = join(parent, "workspace");
  }
  if (!within(path, sessions) || samePath(path, sessions)) return null;
  // Only the station layout sessions/<connect>/<session>/workspace, never an arbitrary nested project.
  const relative = segments(path.slice(sessions.length)).filter((p) => p !== "");
  if (relative.length !== 3 || fileName(path) !== "workspace") return null;
  return dirname(path);
}

/// Whether a directory is one a build or an install makes again: node_modules, a Cargo target, a Gradle build and its
/// cache, Next's and Turbo's caches, Python's bytecode.
export function rebuildable(dir: string): boolean {
  const name = fileName(dir);
  if (name === null) return false;
  const beside = (file: string) => existsSync(join(dirname(dir), file));
  switch (name) {
    case "node_modules":
    case ".next":
    case ".turbo":
    case "__pycache__":
      return true;
    case "target":
      return beside("Cargo.toml");
    case ".gradle":
      return beside("settings.gradle") || beside("settings.gradle.kts") || beside("build.gradle") || beside("build.gradle.kts");
    case "build":
      return beside("build.gradle") || beside("build.gradle.kts");
    default:
      return false;
  }
}

/// Even a generated-looking directory may contain tracked source. If Git cannot inspect a repository, keep it.
/// Standalone generated directories (e.g. a screenshot script's node_modules) do not need a Git repository.
export async function safeToRemove(path: string): Promise<boolean> {
  let isDir = false;
  try {
    isDir = lstatSync(path).isDirectory();
  } catch {}
  if (!isDir || !rebuildable(path)) return false;
  const parent = dirname(path);
  let inRepo = false;
  for (let p = parent; ; p = dirname(p)) {
    if (existsSync(join(p, ".git"))) {
      inRepo = true;
      break;
    }
    if (dirname(p) === p) break;
  }
  if (!inRepo) return true;
  return new Promise((resolve) => {
    execFile("git", ["-C", parent, "ls-files", "--", basename(path)], { encoding: "buffer" }, (error, stdout) => {
      resolve(error === null && stdout.length === 0);
    });
  });
}

/// A chat's own directory (its session's workspace and what is beside it).
export type Room = {
  bytes: number;
  /// What can be made again, in it: directories and their sizes.
  rebuild: [string, number][];
};

export const rebuildBytes = (room: Room) => room.rebuild.reduce((sum, [, b]) => sum + b, 0);

/// Counts files once each however many links they have.
class Seen {
  private seen = new Set<string>();
  bytes(meta: import("node:fs").BigIntStats): number {
    if (meta.nlink > 1n) {
      const id = `${meta.dev}:${meta.ino}`;
      if (this.seen.has(id)) return 0;
      this.seen.add(id);
    }
    return Number(meta.blocks) * 512;
  }
}

/// The size of `path` and everything under it; links are not followed. With `found`, directories that can be made
/// again are listed there (each counted whole, not looked into further).
async function measure(path: string, seen: Seen, found: [string, number][] | null): Promise<number> {
  let meta;
  try {
    meta = await lstat(path, { bigint: true });
  } catch {
    return 0;
  }
  let bytes = seen.bytes(meta);
  if (!meta.isDirectory()) return bytes;
  let entries;
  try {
    entries = await readdir(path, { withFileTypes: true });
  } catch {
    return bytes;
  }
  for (const entry of entries) {
    const child = join(path, entry.name);
    // Never discover cleanup candidates in repository metadata or historical attachments.
    if (found !== null && (entry.name === ".git" || entry.name === "uploads")) {
      bytes += await measure(child, seen, null);
      continue;
    }
    if (found !== null && entry.isDirectory() && rebuildable(child)) {
      const size = await measure(child, seen, null);
      found.push([child, size]);
      bytes += size;
    } else bytes += await measure(child, seen, found);
  }
  return bytes;
}

/// Measures one chat's directory again (after something in it was cleaned).
export async function measureRoom(dir: string): Promise<Room> {
  const rebuild: [string, number][] = [];
  const bytes = await measure(dir, new Seen(), rebuild);
  return { bytes, rebuild };
}

/// The size of a path, each file once (for the tests: footprint.rs `measure` without `found`).
export const measured = (path: string) => measure(path, new Seen(), null);
