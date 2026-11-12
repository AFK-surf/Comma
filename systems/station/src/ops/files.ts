// Files the station keeps: where its data directory is, and writing them whole (a reader never sees half a file).
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, opendirSync, renameSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { tr, type Lang } from "./i18n.ts";
import { wall } from "./fibers.ts";
import { platform } from "../platform/index.ts";

/// The data directory: `--data`, else $COMMA_STATION_DATA, else $EMBER_DATA (before the rename), else ~/.comma-station.
export function dataDir(args: string[]): string {
  const at = args.indexOf("--data");
  if (at >= 0 && args[at + 1]) return args[at + 1];
  return process.env.COMMA_STATION_DATA || process.env.EMBER_DATA || join(homedir(), ".comma-station");
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

/// Whether `dir` is there but the station may not list it (EPERM, EACCES; it may still stat it). It says nothing of
/// why: a file's mode, a flag, or, on macOS, privacy protection (`unreadableDirMessage`).
export function unreadableDir(dir: string): boolean {
  try {
    opendirSync(dir).closeSync();
    return false;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code === "EPERM" || code === "EACCES";
  }
}

/// The desktop app whose station this probably is, by its name in Finder; undefined for one launchd probably runs. A
/// heuristic that picks which hint to give, not a proof of who started the station: the app puts COMMA_APP_PID in its
/// station's environment (the launcher keeps its own --with-parent to itself), and a station started by hand may have
/// it or not. macOS attributes the file access of the app's child to the app and asks for it by that name; it never
/// asks for a station launchd runs.
function appName(argv: string[], env: NodeJS.ProcessEnv): string | undefined {
  const app = flag(argv, "--app");
  if (app && !env.COMMA_APP_PID) return undefined;
  const bundle = app?.split("/").find((part) => part.endsWith(".app"));
  return bundle ? bundle.slice(0, -".app".length) : "Comma";
}

/// The installed station's launcher, the program Full Disk Access is given to.
const launcherPath = (argv: string[]) => join(flag(argv, "--app") ?? "", "mesh", "target", "release", "comma-station");

/// Where the user may allow access, if privacy protection is the cause: the app's answer is kept under Files and
/// Folders; only Full Disk Access for its comma-station lets a station launchd runs in.
function folderAccessPlace(lang: Lang, argv: string[], env: NodeJS.ProcessEnv): string {
  const program = appName(argv, env);
  if (program) return tr(lang, "station.files.grantApp", { program });
  return tr(lang, "station.files.grantInstalled", { program: launcherPath(argv) });
}

/// The folders in the home that macOS asks about for each app the first time it opens them.
const PROMPTED_FOLDERS = ["Desktop", "Documents", "Downloads"];

/// Whether `path` is in one of the folders macOS asks about (`PROMPTED_FOLDERS`), on a Mac.
export function inPromptedFolder(path: string, home = homedir()): boolean {
  if (!platform.hasFolderPermissions) return false;
  return PROMPTED_FOLDERS.some((name) => {
    const dir = join(home, name);
    return path === dir || path.startsWith(`${dir}/`);
  });
}

/// The folders macOS asks about that a walk of `dir` opens, when `dir` holds the home or is it; none on other systems.
export function promptedFoldersWithin(dir: string, home = homedir()): string[] {
  if (!platform.hasFolderPermissions) return [];
  const below = relative(dir, home);
  if (below === ".." || below.startsWith("../") || isAbsolute(below)) return [];
  return PROMPTED_FOLDERS.map((name) => join(home, name));
}

/// The file system calls macOS privacy protection gates in those folders: opening, listing, creating, renaming and
/// removing their files.
const GATED_CALLS = new Set(["open", "opendir", "scandir", "rename", "unlink", "mkdir", "rmdir", "copyfile"]);

/// This computer's screen, as a link the client shows as its card when it is on a line of its own
/// (`comma:screen/<device id>/display`): people mostly use Comma from another device and do not see this one.
function screenLine(lang: Lang, deviceId: string | undefined): string {
  if (!deviceId) return "";
  return `\n\n${tr(lang, "station.files.openScreen")}\n\ncomma:screen/${encodeURIComponent(deviceId)}/display\n`;
}

/// What is added where privacy protection is a possible cause: where the user may allow it, and the computer's screen.
function privacyHint(lang: Lang, path: string, place: FileErrorPlace): string {
  const { argv = process.argv, env = process.env } = place;
  return `${tr(lang, "station.files.maybePrivacy", { path })} ${folderAccessPlace(lang, argv, env)}${screenLine(lang, place.deviceId)}`;
}

/// What to tell when an agent's directory is unreadable (`unreadableDir`). In a folder macOS asks about, privacy
/// protection is added as a possible cause, with where the user may allow it.
export function unreadableDirMessage(lang: Lang, dir: string, argv = process.argv, env = process.env): string {
  const denied = tr(lang, "station.session.cwdDenied", { cwd: dir });
  if (!inPromptedFolder(dir, env.HOME || homedir())) return denied;
  return `${denied}. ${tr(lang, "station.files.maybePrivacy", { path: dir })} ${folderAccessPlace(lang, argv, env)}`;
}

/// Where this Mac's station is, for what it tells about its permissions: the device id Salix gave its connection and
/// the home its folders are in.
export type FileErrorPlace = { deviceId?: string; home?: string; argv?: string[]; env?: NodeJS.ProcessEnv };

/// What the agent is told for a failed file operation: the error as the file system said it. An EPERM proves no cause
/// (an immutable file gives one too), so only for a call privacy protection gates, in a folder macOS asks about, is
/// privacy protection added as a possible cause, with where the user may allow it and the computer's screen to do it
/// from.
export function fileErrorMessage(lang: Lang, error: Error, place: FileErrorPlace = {}): string {
  const { argv = process.argv, env = process.env } = place;
  const { code, path, syscall } = error as NodeJS.ErrnoException;
  if (code !== "EPERM" || !path || !syscall || !GATED_CALLS.has(syscall)) return error.message;
  if (!inPromptedFolder(path, place.home ?? (env.HOME || homedir()))) return error.message;
  return `${error.message}. ${privacyHint(lang, path, place)}`;
}

const NOT_PERMITTED = /operation not permitted/i;
// How macOS's tools and the common runtimes name the path: quoted (Python, Node, git, rsync), after the words (zsh),
// or before them (`ls: Downloads: Operation not permitted`, `mv: rename a to /x/b: Operation not permitted`).
const QUOTED_PATH = /['"`]([^'"`]+)['"`]/g;
const PATH_AFTER = /operation not permitted:\s*(.+)$/i;
const PATH_BEFORE = /(?:^|:\s)([^:'"]*?):\s*operation not permitted/i;

/// The paths a line that says "Operation not permitted" may be about.
function namedPaths(line: string): string[] {
  const quoted = [...line.matchAll(QUOTED_PATH)].map((match) => match[1]!);
  const after = PATH_AFTER.exec(line)?.[1]?.trim();
  const before = PATH_BEFORE.exec(line)?.[1]?.trim();
  return [...quoted, ...(after ? [after] : []), ...(before ? [before, ...before.split(/\s+/)] : [])];
}

/// The first path in a folder macOS asks about that a line of `text` says it may not touch. Such a line picks the
/// hint, not the exit code. It proves no cause: an immutable file says the same, and a command can echo the words, so
/// the hint gives privacy protection only as a possible cause. `~` is the home; a relative path is under `cwd`.
function deniedInPromptedFolder(text: string, cwd: string, home: string): string | undefined {
  for (const line of text.split("\n")) {
    if (!NOT_PERMITTED.test(line)) continue;
    for (const named of namedPaths(line)) {
      const path = resolve(cwd, named === "~" ? home : named.startsWith("~/") ? join(home, named.slice(2)) : named);
      if (inPromptedFolder(path, home)) return path;
    }
  }
  return undefined;
}

/// A command's result, as an agent's shell command on this computer is answered. A file's text on stdout can say
/// anything, so stdout (`ls ... 2>&1`) counts only for a command that failed; stderr is the command's own say, and
/// `ls ~/Downloads | head` exits 0. Where a line says a protected folder was denied, stderr also also gets what `fileErrorMessage` adds.
export function withFolderDenialHint<R extends { exit_code: number | null; stdout: string; stderr: string }>(lang: Lang, result: R, cwd: string, place: FileErrorPlace = {}): R {
  if (!platform.hasFolderPermissions) return result;
  const home = place.home ?? ((place.env ?? process.env).HOME || homedir());
  const path = deniedInPromptedFolder(result.stderr, cwd, home) ?? (result.exit_code === 0 ? undefined : deniedInPromptedFolder(result.stdout, cwd, home));
  if (!path) return result;
  const hint = privacyHint(lang, path, place);
  return { ...result, stderr: result.stderr === "" || result.stderr.endsWith("\n") ? `${result.stderr}${hint}` : `${result.stderr}\n${hint}` };
}

/// What the agent is told when a read of `path` (in `PROMPTED_FOLDERS`) has not finished in `seconds`; that is all that
/// is known. For the app's station macOS may hold the first open until someone answers its prompt on this computer,
/// which nobody may be at, so the user is asked to look, and slow I/O is the other cause. A station launchd runs is
/// never asked, so there slow I/O is a possible cause, not a prompt. The read goes on and its result is dropped; asking again later works.
export function slowFolderReadMessage(lang: Lang, path: string, seconds: number, place: FileErrorPlace = {}): string {
  const { argv = process.argv, env = process.env } = place;
  const program = appName(argv, env);
  if (program) return `${tr(lang, "station.files.slowReadApp", { path, seconds, program })}${screenLine(lang, place.deviceId)}`;
  return tr(lang, "station.files.slowReadInstalled", { path, seconds, program: launcherPath(argv) });
}

/// The station's database in `data`: the file a station from before the rename made, while it is there.
export const storeFile = (data: string): string => (existsSync(join(data, "stillfail.db")) ? join(data, "stillfail.db") : join(data, "station.db"));
