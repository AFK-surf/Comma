// Files the station keeps: where its data directory is, and writing them whole (a reader never sees half a file).
import { closeSync, fsyncSync, mkdirSync, openSync, opendirSync, renameSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { tr, type Lang } from "./i18n.ts";
import { wall } from "./fibers.ts";
import { platform } from "../platform/index.ts";

/// The data directory: `--data`, else $STILLFAIL_DATA, else $EMBER_DATA (before the rename), else ~/.stillfail.
export function dataDir(args: string[]): string {
  const at = args.indexOf("--data");
  if (at >= 0 && args[at + 1]) return args[at + 1];
  return process.env.STILLFAIL_DATA || process.env.EMBER_DATA || join(homedir(), ".stillfail");
}

/// The station's runtime state: what is true of one run of it on one boot of one machine (its lock, pid and ports, its
/// presence, a handover's snapshot, an update under way, the runners' records, sockets and output). Nothing durable is
/// kept here and nothing here is trusted by itself after the boot it was written in: an archive of the station's disk
/// leaves it out, and a restore drops it from an archive that has it (connector/service.ts `stationArchiveState`).
export const runtimeDir = (data: string) => join(data, "run");

/// The value after `flag` in argv, wherever it is (as the Rust station reads its flags).
export function flag(args: string[], name: string): string | undefined {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
}

/// Written beside and renamed into place, synced, readable by its owner only.
export function writePrivate(path: string, data: string | Uint8Array) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeSync(fd, typeof data === "string" ? Buffer.from(data) : data);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
}

/// Seconds, as the cloud and the files say them: the machine's time.
export const nowSecs = () => Math.floor(wall.now() / 1000);

/// Whether `dir` is there but the station may not list it (EPERM, EACCES; it may still stat it). On macOS a folder the
/// system's privacy protection keeps (Documents, Desktop, Downloads, removable and network volumes) answers EPERM to a
/// process nobody gave access to, and a station launchd runs is never asked: an agent started there exits at once,
/// saying nothing of why.
export function unreadableDir(dir: string): boolean {
  try {
    opendirSync(dir).closeSync();
    return false;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code === "EPERM" || code === "EACCES";
  }
}

/// What to tell when an agent's directory is unreadable (`unreadableDir`): on macOS, who to give access to and where.
/// The desktop app runs its station with --with-parent and is the one macOS asks about; an installed station is its
/// stillfail-station.
export function unreadableDirMessage(lang: Lang, dir: string, argv = process.argv): string {
  if (!platform.hasFolderPermissions) return tr(lang, "station.session.cwdDenied", { cwd: dir });
  const app = flag(argv, "--app");
  const program = argv.includes("--with-parent") || !app ? "still.fail" : join(app, "mesh", "target", "release", "stillfail-station");
  return tr(lang, "station.session.cwdDeniedMac", { cwd: dir, program });
}
