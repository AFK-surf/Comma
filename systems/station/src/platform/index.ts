// What differs between the machines a station runs on (macOS, Linux, Windows), in this directory and nowhere else:
// the rest of src/ is one logic for all of them, and asks `platform` for what a machine does its own way
// (test/platform.test.ts keeps it so: no process.platform, `win32` or WINDOWS outside src/platform/).
//
// What is asked is what the station means to do (end a job's group, make a command another program can run, join a
// path as Rust does), not which machine this is; a feature only one machine has is a flag saying so (hasKeychain).
import type { ChildProcess } from "node:child_process";
import type { Lang } from "../ops/i18n.ts";
import { unix } from "./unix.ts";
import { windows } from "./windows.ts";

export type Env = Record<string, string | undefined>;
/// A command found on PATH: as found there, and the file it is once links are followed.
export type Found = { onPath: string; real: string };
/// A program and its arguments, as runtimes are installed and updated.
export type How = { program: string; args: string[] };

/// How the host page says the machine (GET /host): memory, CPU, uptime, the OS.
export type Host = {
  /// CPU time since boot, all CPUs together: (busy, total); none when it cannot be read.
  cpuTicks(): [busy: number, total: number] | null;
  memory(): { totalBytes: number; usedBytes: number; swapUsedBytes: number | null };
  cpuModel(): string;
  uptimeSec(): number;
  osName(): string;
  /// This process's resident memory.
  ownRss(): number;
};

export type Platform = {
  /// std::env::consts::OS as Rust names it (macos, linux, windows; another its own name): what a station says it runs
  /// on to its peers and in feedback.
  os: string;
  /// How the runtimes name a build's OS (darwin, linux, win32); none for another.
  buildOs: string | null;
  /// The OS as Go names it (darwin, linux, windows): what Salix keeps of a connector's machine.
  goOs: string;

  // Commands and their environment.
  /// An executable's file name (`stillfail-runner` → `stillfail-runner.exe` on Windows).
  exe(name: string): string;
  /// The user's home as `env` says it.
  home(env: Env): string | undefined;
  /// PATH as `env` has it (on Windows `Path` as often as not).
  pathOf(env: Env): string;
  /// `env` with `dir` first on its PATH (one PATH variable, whatever its case).
  prependPath(env: NodeJS.ProcessEnv, dir: string): NodeJS.ProcessEnv;
  /// A command on `env`'s PATH as a shell finds it (with PATHEXT's extensions on Windows).
  findCommand(name: string, env: Env): Found | null;
  /// How Node runs a command (a name on PATH, or a path) with `args`: on Windows a .cmd is run around cmd when it can
  /// be (npm's, Vite+'s), else through it, quoted.
  runnable(command: string, args: string[], env: NodeJS.ProcessEnv): { file: string; args: string[]; windowsVerbatimArguments?: true };
  /// The shell jobs and device commands run under (/bin/sh; Git for Windows' sh).
  posixShell(env?: NodeJS.ProcessEnv): string;
  /// `command` run by PowerShell (a device command that asks for it): pwsh where there is one, else Windows' own
  /// powershell.exe; none on a machine with neither. Its output is UTF-8 whatever the console's code page.
  powerShell(command: string, env: NodeJS.ProcessEnv): How | null;
  /// A command as a group of its own, ended whole (as spawned detached on Unix; under `stillfail-runner --job` on
  /// Windows).
  grouped(program: string, args: string[]): [string, string[]];
  /// A command started `by` lower in CPU priority than this process (ops/nice.ts): under nice where there is one; as
  /// it is on Windows (no nice).
  lowered(program: string, args: string[], by: number): [string, string[]];
  /// A shell script at `path` runnable by name from any shell: on Windows a `.cmd` beside it too, running it with the
  /// POSIX shell, or doing nothing when `noop`. The name a program is to be given for it (the .cmd on Windows).
  makeCommand(path: string, script: string, noop?: boolean): string;

  // Process groups (jobs/group.ts).
  /// Signals a whole group; one already gone is no error. On Windows any signal ends it.
  signalGroup(pgid: number, signal: NodeJS.Signals): void;
  /// Signals a child that leads a group (spawned detached, or `grouped`), and what it started.
  signalChildGroup(child: ChildProcess, signal: NodeJS.Signals): void;
  /// Whether any process of the group is there.
  groupAlive(pgid: number): boolean;
  /// When `pid` started (ms), none when it is not running or cannot be read.
  startTimeOf(pid: number): number | null;
  /// Whether a group lives on without its leader (a Unix group while any member does; a Windows job dies with it).
  groupOutlivesLeader: boolean;
  /// Memory of each group (kB).
  groupMemory(pgids: number[]): Promise<Map<number, number>>;

  // Paths.
  paths: {
    /// What separates a path's components.
    separator: RegExp | string;
    /// The separator a path is joined with.
    sep: string;
    /// A path absolute, `.` and `..` worked out lexically (no link followed).
    clean(path: string): string;
    /// What two paths are compared by (on Windows case does not tell them apart).
    key(path: string): string;
    /// Path::starts_with on keyed paths: `path` is `dir` or under it.
    within(path: string, dir: string): boolean;
    /// Whether a path's only component is a root and not a name (a drive, `C:`).
    isRootName(part: string): boolean;
    /// Whether a path given as relative starts somewhere of its own: `/`; on Windows also a drive, a share or a
    /// stream (`a:b`).
    rooted(path: string): boolean;
    /// Path::join as Rust has it: an absolute `given` replaces `base`; nothing is normalised.
    join(base: string, given: string): string;
    /// `path` relative to `root` when it is `root` or under it (whole components), else none.
    relativeIn(root: string, path: string): string | null;
    /// Whether a link's text is a local path by its form alone (on Windows a drive's path, `C:\…`).
    isDrivePath(text: string): boolean;
  };

  // Files.
  /// Whether making a symbolic link was refused for want of the privilege (Windows without Developer Mode).
  linkRefused(error: unknown): boolean;
  /// Whether a directory's entries can be made durable by syncing it (not on Windows: NTFS journals them).
  syncsDirectories: boolean;
  /// Whether a directory can be held open and its entries opened relative to it without following links (openat; Node
  /// on Windows opens no directory).
  opensDirectories: boolean;
  /// Whether a file's mode says who may read it (not on Windows: its ACL does, and its mode is 0o666 or 0o444).
  modesArePrivate: boolean;
  /// `link` the same file as `target`, kept so: a symbolic link, or where one is refused a hard link.
  shareFile(target: string, link: string): void;

  // The runner (agents/runner.ts).
  /// Whether a runner's socket is a file that can be looked at without connecting (not a Windows pipe).
  runnerSocketVisible: boolean;
  /// Whether the station says `leave` before letting go of a runner (a pipe has no closing of one side).
  runnerSaysLeave: boolean;

  // The machine (read/host.ts).
  host: Host;

  // The launcher (native/launcher), as the CLI and the station's own update reach it.
  /// Whether process `pid` is a station's launcher (pids get reused).
  isLauncher(pid: number): boolean;
  /// Asks the launcher `pid` to hand over to a new process, to drain, or to read the channel again: Unix's SIGUSR2,
  /// SIGUSR1, SIGHUP; on Windows, which has no signals, a line on its own pipe. Throws when it is not reached.
  askLauncher(pid: number, op: "handover" | "drain" | "hup"): Promise<void>;

  // Updates.
  /// How Claude Code is installed where it is not.
  claudeInstall: How;
  /// Starts the cloud's installer apart from the station, its exit to run/update.exit and what it said to
  /// run/update.log. Whether it was started.
  startInstaller(origin: string, runDir: string, env: Record<string, string>, app: string, lang: Lang): Promise<boolean>;
  /// How a runtime found as a package manager's shim of this machine's kind is updated (Windows: Vite+'s beside
  /// vp.exe, npm's .cmd in its prefix), none for the shared rules.
  shimUpdate(found: Found, pkg: string, env: Env): How | "no-npm" | null;
  /// Whether Codex's standalone install updates by its installer here (a shell script: not on Windows).
  codexStandalone: boolean;

  // What only some machines have.
  /// The macOS keychain (Claude Code keeps its login there).
  hasKeychain: boolean;
  /// QuickLook's thumbnails (qlmanage).
  hasQuickLook: boolean;
  /// Privacy permissions a folder can be denied by (macOS's).
  hasFolderPermissions: boolean;
  /// Computer Use's helper app (native/macos), which the desktop app carries on macOS only.
  hasComputerUse: boolean;
  /// Homebrew's bin directories, looked in for runtimes beside PATH (a launchd PATH has neither).
  hasHomebrew: boolean;
};

export const platform: Platform = process.platform === "win32" ? windows : unix;
/// For tests and the few places that must say which: whether this is Windows.
export const WINDOWS = process.platform === "win32";
