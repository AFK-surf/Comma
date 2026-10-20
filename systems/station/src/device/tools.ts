// The device tools (contract v1 §8, `comma/tools/1`): what a control plane's gateway may do on this machine for its
// agents — run a command, read and write files, keep processes, see which runtimes are here, and start and drive the
// station's own chats. Each op is an Effect; what it refuses is a ToolError with a stable code. How far the gateway
// may go is the computer's one access value (src/device/access.ts: `tools.access` in config.json, off | read | full),
// which the device connector to Salix follows too. Under every level the station's own data (its key, cloud.json,
// config, the profiles' homes) and the machine's runtime logins are refused to the file ops and as a working directory
// (`protect`); `exec` and `process.*` under `full` run as the station's user and can reach what that user can, which is
// why they need `full`.
import { type ChildProcess, execFile } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { appendFile, lstat, mkdir, open, readdir, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, resolve, sep } from "node:path";
import { Data, Effect } from "effect";
import { claudeCredentialsFile, codexAuthFile } from "../agents/machine-logins.ts";
import { findCommand } from "../updates/runtimes.ts";
import { versionIn } from "../updates/versions.ts";
import { wall } from "../ops/fibers.ts";
import { endCommand, startCommand } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import type { Access } from "./access.ts";

export { type Access, ACCESS, DEFAULT_ACCESS, accessOf } from "./access.ts";

/// What `read` lets through — every file this user can read except the station's own data (and the machine's logins),
/// processes, runtimes and chat states; `full` lets everything through, `off` nothing.
export const READ_OPS: readonly string[] = ["fs.read", "fs.list", "fs.stat", "runtime.probe", "process.list", "process.tail", "session.status"];

export const OPS: readonly string[] = [
  "exec", "fs.read", "fs.write", "fs.list", "fs.stat",
  "process.start", "process.write", "process.tail", "process.stop", "process.list",
  "runtime.probe", "session.start", "session.say", "session.status",
];

export function permitted(access: Access, op: string): boolean {
  return access === "full" || (access === "read" && READ_OPS.includes(op));
}

/// Why an op was not done: `code` for machines (invalid_request, forbidden, not_found, unknown_op, failed, timeout…).
export class ToolError extends Data.TaggedError("ToolError")<{ readonly code: string; readonly message: string }> {}

const fail = (code: string, message: string) => Effect.fail(new ToolError({ code, message }));

/// Who asked, as the gateway says (contract §8): the workspace, the person and the agent's conversation.
export type Context = { workspace?: string; user_id?: string; user_email?: string; agent?: string; conversation?: string };

/// The station's chats, as the pages make and drive them (src/mesh/tools.ts gives them through the admin API).
export type Sessions = {
  start(args: { prompt: string; title: string | null; runtime: string | null; model?: string | null; effort?: string | null; requester: string }): Promise<{ session: string; thread: string }>;
  say(args: { thread: string; text: string; requester: string }): Promise<void>;
  status(thread: string): { state: "running" | "all_done" | "need_human" | "waiting" | "idle"; summary?: string } | null;
};

export const OUTPUT_CAP = 1024 * 1024;
export const READ_CAP = 8 * 1024 * 1024;
const EXEC_TIMEOUT_MS = 120_000;
const EXEC_TIMEOUT_MAX_MS = 600_000;
/// What a kept process's output keeps (its latest), and how many are kept at once.
const PROCESS_KEEP = 4 * 1024 * 1024;
const MAX_PROCESSES = 32;

type Kept = {
  id: string;
  command: string;
  child: ChildProcess;
  startedAt: number;
  /// Its output, both streams in order of arrival: `chunks` from byte `base` on, `total` bytes so far.
  chunks: Buffer[];
  base: number;
  total: number;
  exited: boolean;
  exitCode: number | null;
};

// ── arguments ──

type Args = Record<string, unknown>;
const str = (a: Args, k: string) => (typeof a[k] === "string" ? (a[k] as string) : null);
const need = (a: Args, k: string) => {
  const v = str(a, k);
  return v === null || v === "" ? fail("invalid_request", `${k} is required`) : Effect.succeed(v);
};
const int = (a: Args, k: string): number | null => (typeof a[k] === "number" && Number.isInteger(a[k]) && (a[k] as number) >= 0 ? (a[k] as number) : null);
const envOf = (a: Args): Record<string, string> | null => {
  const e = a.env;
  if (e === undefined || e === null) return {};
  if (typeof e !== "object" || Array.isArray(e) || Object.values(e).some((v) => typeof v !== "string")) return null;
  return e as Record<string, string>;
};

/// A path as asked: absolute, or from the station's home directory.
const pathOf = (home: string, p: string) => (isAbsolute(p) ? p : resolve(home, p));

const io = <A>(f: () => Promise<A>) =>
  Effect.tryPromise({
    try: f,
    catch: (e) => {
      const code = (e as NodeJS.ErrnoException).code;
      return new ToolError({ code: code === "ENOENT" ? "not_found" : code === "EACCES" || code === "EPERM" ? "forbidden" : "failed", message: (e as Error).message });
    },
  });

const kindOf = (s: { isFile(): boolean; isDirectory(): boolean; isSymbolicLink(): boolean }) => (s.isFile() ? "file" : s.isDirectory() ? "dir" : s.isSymbolicLink() ? "symlink" : "other");

/// A path as the file system has it: its links followed and each name as it is on disk (a case-insensitive file system
/// takes `DATA` for `data`), as far as it exists (what is not there yet is under its nearest parent that is).
function real(path: string): string {
  try {
    return realpathSync.native(path);
  } catch {
    const parent = dirname(path);
    return parent === path ? path : resolve(real(parent), basename(path));
  }
}

const within = (path: string, root: string) => path === root || path.startsWith(root.endsWith(sep) ? root : root + sep);

export type DeviceToolsOptions = {
  /// Where relative paths and commands start: the station's user's home by default.
  home?: string;
  /// What no op may touch, at any level: the station's data directory, its config, the machine's runtime logins
  /// (asked anew at each op: a profile's home may be added meanwhile).
  protect?: () => string[];
  env?: Record<string, string | undefined>;
  sessions?: Sessions;
  now?: () => number;
};

export class DeviceTools {
  readonly home: string;
  private env: Record<string, string | undefined>;
  private sessions: Sessions | undefined;
  private now: () => number;
  private protect: () => string[];
  private processes = new Map<string, Kept>();
  private next = 1;

  constructor(options: DeviceToolsOptions = {}) {
    this.home = options.home ?? homedir();
    this.env = options.env ?? process.env;
    this.sessions = options.sessions;
    this.now = options.now ?? wall.now;
    this.protect = options.protect ?? (() => []);
  }

  /// `path` as an op may use it: absolute (from the home when relative), and none of what is protected, by its own
  /// name or through a link.
  private allowed(path: string): Effect.Effect<string, ToolError> {
    const asked = pathOf(this.home, path);
    const found = real(asked);
    for (const root of this.protect()) {
      const r = real(root);
      if (within(asked, root) || within(found, r) || within(asked, r) || within(found, root)) return fail("forbidden", "the station's own data and the machine's logins are not reachable through device tools");
    }
    return Effect.succeed(asked);
  }

  private path(a: Args, k: string) {
    return Effect.flatMap(need(a, k), (p) => this.allowed(p));
  }

  /// A working directory: the home, or one asked for that is allowed.
  private cwd(a: Args) {
    return this.allowed(str(a, "cwd") ?? this.home);
  }

  /// Every kept process stopped (the station stops).
  close() {
    for (const p of this.processes.values()) if (!p.exited) killGroup(p.child, "SIGKILL");
    this.processes.clear();
  }

  /// One op, as `access` lets it: its result, or why not.
  run(op: string, args: Args, context: Context, access: Access): Effect.Effect<unknown, ToolError> {
    if (!OPS.includes(op)) return fail("unknown_op", `unknown op ${op}`);
    if (!permitted(access, op)) return fail("forbidden", access === "off" ? "device tools are turned off on this station" : `${op} needs full access; this station allows ${access}`);
    const a = args ?? {};
    switch (op) {
      case "exec":
        return this.exec(a);
      case "fs.read":
        return this.read(a);
      case "fs.write":
        return this.write(a);
      case "fs.list":
        return this.list(a);
      case "fs.stat":
        return this.stat(a);
      case "process.start":
        return this.start(a);
      case "process.write":
        return this.processWrite(a);
      case "process.tail":
        return this.tail(a);
      case "process.stop":
        return this.stop(a);
      case "process.list":
        return Effect.succeed({ processes: [...this.processes.values()].map((p) => this.shown(p)) });
      case "runtime.probe":
        return this.probe();
      default:
        return this.session(op, a, context);
    }
  }

  // ── exec ──

  private exec(a: Args): Effect.Effect<unknown, ToolError> {
    const self = this;
    return Effect.gen(function* () {
      const command = yield* need(a, "command");
      const env = envOf(a);
      if (env === null) return yield* fail("invalid_request", "env must be a map of strings");
      const timeout = Math.min(int(a, "timeout_ms") ?? EXEC_TIMEOUT_MS, EXEC_TIMEOUT_MAX_MS);
      const cwd = yield* self.cwd(a);
      // A POSIX shell by default, on every machine (Git's sh on Windows); PowerShell when asked for.
      const shell = typeof a.shell === "string" && a.shell !== "" ? a.shell : "sh";
      if (shell !== "sh" && shell !== "powershell") return yield* fail("invalid_request", "shell is sh or powershell");
      const how = shell === "powershell" ? platform.powerShell(command, { ...self.env, ...env }) : { program: platform.posixShell(self.env), args: ["-c", command] };
      if (how === null) return yield* fail("failed", "PowerShell is not on this machine");
      return yield* Effect.callback<{ exit_code: number | null; stdout: string; stderr: string; truncated: boolean; timed_out?: boolean }, ToolError>((resume) => {
        let child: ChildProcess;
        try {
          child = startCommand(how.program, how.args, { cwd, env: { ...self.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
        } catch (e) {
          resume(fail("failed", (e as Error).message));
          return;
        }
        const out = capture(child.stdout!);
        const err = capture(child.stderr!);
        let timedOut = false;
        // How long a command is given is the machine's time (ops/fibers.ts `wall`).
        const cancel = wall.after(timeout, () => {
          timedOut = true;
          killGroup(child, "SIGKILL");
        });
        child.on("error", (e) => {
          cancel();
          resume(fail("failed", e.message));
        });
        child.on("close", (code) => {
          cancel();
          const result = { exit_code: code, stdout: out.text(), stderr: err.text(), truncated: out.truncated() || err.truncated() };
          resume(timedOut ? Effect.succeed({ ...result, timed_out: true }) : Effect.succeed(result));
        });
        // Interrupted (the gateway went): the command goes too.
        return Effect.sync(() => {
          cancel();
          killGroup(child, "SIGKILL");
        });
      });
    });
  }

  // ── files ──

  private read(a: Args) {
    const self = this;
    return Effect.gen(function* () {
      const path = yield* self.path(a, "path");
      const offset = int(a, "offset") ?? 0;
      const length = Math.min(int(a, "length") ?? READ_CAP, READ_CAP);
      return yield* io(async () => {
        const file = await open(path, "r");
        try {
          const { size } = await file.stat();
          const want = Math.max(0, Math.min(length, size - offset));
          const buffer = Buffer.alloc(want);
          const { bytesRead } = want > 0 ? await file.read(buffer, 0, want, offset) : { bytesRead: 0 };
          return { content_base64: buffer.subarray(0, bytesRead).toString("base64"), size, eof: offset + bytesRead >= size };
        } finally {
          await file.close();
        }
      });
    });
  }

  private write(a: Args) {
    const self = this;
    return Effect.gen(function* () {
      const path = yield* self.path(a, "path");
      const content = str(a, "content_base64");
      if (content === null) return yield* fail("invalid_request", "content_base64 is required");
      const bytes = Buffer.from(content, "base64");
      return yield* io(async () => {
        await mkdir(dirname(path), { recursive: true });
        if (a.append === true) await appendFile(path, bytes);
        else await writeFile(path, bytes);
        return { size: (await stat(path)).size };
      });
    });
  }

  private list(a: Args) {
    const self = this;
    return Effect.gen(function* () {
      const path = yield* self.path(a, "path");
      return yield* io(async () => {
        const names = (await readdir(path)).sort();
        const entries = [];
        for (const name of names) {
          try {
            const s = await lstat(resolve(path, name));
            entries.push({ name, type: kindOf(s), size: s.size, mtime_ms: Math.floor(s.mtimeMs) });
          } catch {
            // Gone meanwhile.
          }
        }
        return { entries };
      });
    });
  }

  private stat(a: Args) {
    const self = this;
    return Effect.gen(function* () {
      const path = yield* self.path(a, "path");
      return yield* io(async () => {
        const s = await lstat(path);
        return { path, type: kindOf(s), size: s.size, mtime_ms: Math.floor(s.mtimeMs), mode: s.mode & 0o7777 };
      });
    });
  }

  // ── processes ──

  private start(a: Args) {
    const self = this;
    return Effect.gen(function* () {
      const command = yield* need(a, "command");
      const env = envOf(a);
      if (env === null) return yield* fail("invalid_request", "env must be a map of strings");
      // The oldest ended ones make room; running ones are never dropped.
      if (self.processes.size >= MAX_PROCESSES) {
        for (const [id, p] of self.processes) if (p.exited && self.processes.size >= MAX_PROCESSES) self.processes.delete(id);
        if (self.processes.size >= MAX_PROCESSES) return yield* fail("too_many_processes", `at most ${MAX_PROCESSES} processes are kept; stop one first`);
      }
      const cwd = yield* self.cwd(a);
      const id = `p${self.next++}`;
      const child = yield* Effect.try({
        try: () => startCommand(platform.posixShell(self.env), ["-c", command], { cwd, env: { ...self.env, ...env }, stdio: ["pipe", "pipe", "pipe"] }),
        catch: (e) => new ToolError({ code: "failed", message: (e as Error).message }),
      });
      const kept: Kept = { id, command, child, startedAt: self.now(), chunks: [], base: 0, total: 0, exited: false, exitCode: null };
      const take = (chunk: Buffer) => {
        kept.chunks.push(chunk);
        kept.total += chunk.length;
        let held = kept.total - kept.base;
        while (held > PROCESS_KEEP && kept.chunks.length > 1) {
          const dropped = kept.chunks.shift()!;
          kept.base += dropped.length;
          held -= dropped.length;
        }
      };
      child.stdout!.on("data", take);
      child.stderr!.on("data", take);
      child.stdin!.on("error", () => {});
      child.on("error", (e) => {
        take(Buffer.from(`\n[failed: ${e.message}]\n`));
        kept.exited = true;
      });
      child.on("close", (code) => {
        kept.exited = true;
        kept.exitCode = code;
      });
      self.processes.set(id, kept);
      return { process_id: id };
    });
  }

  private kept(a: Args) {
    return Effect.flatMap(need(a, "process_id"), (id) => {
      const p = this.processes.get(id);
      return p === undefined ? fail("not_found", `no process ${id}`) : Effect.succeed(p);
    });
  }

  private processWrite(a: Args) {
    return Effect.flatMap(this.kept(a), (p) => {
      const data = str(a, "data_base64");
      if (data === null) return fail("invalid_request", "data_base64 is required");
      if (p.exited) return fail("exited", `process ${p.id} has exited`);
      return Effect.callback<{}, ToolError>((resume) => {
        p.child.stdin!.write(Buffer.from(data, "base64"), (e) => resume(e ? fail("failed", e.message) : Effect.succeed({})));
      });
    });
  }

  private tail(a: Args) {
    return Effect.map(this.kept(a), (p) => {
      const since = Math.max(int(a, "since") ?? 0, p.base);
      const all = Buffer.concat(p.chunks);
      const data = all.subarray(Math.min(since - p.base, all.length));
      const out: Record<string, unknown> = { data_base64: data.toString("base64"), next: p.total, exited: p.exited };
      if (p.exited) out.exit_code = p.exitCode;
      return out;
    });
  }

  private stop(a: Args) {
    return Effect.map(this.kept(a), (p) => {
      if (!p.exited) killGroup(p.child, "SIGTERM");
      return { process_id: p.id, exited: p.exited };
    });
  }

  private shown(p: Kept) {
    return { process_id: p.id, command: p.command, pid: p.child.pid ?? null, started_at_ms: p.startedAt, exited: p.exited, exit_code: p.exitCode };
  }

  // ── runtimes ──

  private probe() {
    const env = this.env;
    return Effect.promise(async () => {
      const runtimes = [];
      for (const kind of ["claude", "codex"] as const) {
        const found = findCommand(kind, env);
        if (found === null) continue;
        const r = platform.runnable(found.real, ["--version"], env as NodeJS.ProcessEnv);
        const said = await new Promise<string>((done) =>
          execFile(r.file, r.args, { timeout: 10_000, env: env as NodeJS.ProcessEnv, windowsVerbatimArguments: r.windowsVerbatimArguments }, (_e, out) => done(String(out ?? ""))),
        );
        runtimes.push({ kind, path: found.onPath, version: versionIn(said), signed_in: signedIn(kind, env) });
      }
      return { runtimes };
    });
  }

  // ── the station's chats ──

  private session(op: string, a: Args, context: Context): Effect.Effect<unknown, ToolError> {
    const sessions = this.sessions;
    if (sessions === undefined) return fail("unavailable", "this station runs no chats");
    const requester = () => {
      const email = str(a, "requester_email") ?? context.user_email ?? null;
      return email === null || email === "" ? fail("invalid_request", "requester_email is required") : Effect.succeed(email);
    };
    const refused = (e: unknown) => new ToolError({ code: (e as { code?: string }).code ?? "failed", message: (e as Error).message });
    switch (op) {
      case "session.start":
        return Effect.gen(function* () {
          const prompt = yield* need(a, "prompt");
          const requesterEmail = yield* requester();
          return yield* Effect.tryPromise({ try: () => sessions.start({ prompt, title: str(a, "title"), runtime: str(a, "runtime"), requester: requesterEmail }), catch: refused });
        });
      case "session.say":
        return Effect.gen(function* () {
          const thread = yield* need(a, "thread");
          const text = yield* need(a, "text");
          const requesterEmail = yield* requester();
          yield* Effect.tryPromise({ try: () => sessions.say({ thread, text, requester: requesterEmail }), catch: refused });
          return {};
        });
      default:
        return Effect.flatMap(need(a, "thread"), (thread) => {
          const status = sessions.status(thread);
          return status === null ? fail("not_found", `no chat ${thread}`) : Effect.succeed(status);
        });
    }
  }
}

/// Signed in on this machine, as the runtime keeps it (the machine's own login; profiles keep theirs apart).
function signedIn(kind: "claude" | "codex", env: Record<string, string | undefined>): boolean {
  try {
    if (kind === "codex") return existsSync(codexAuthFile(env));
    if (env.ANTHROPIC_API_KEY) return true;
    const file = claudeCredentialsFile(env);
    return existsSync(file) && readFileSync(file, "utf8").includes("accessToken");
  } catch {
    return false;
  }
}

/// A stream's text, the first OUTPUT_CAP bytes of it.
function capture(stream: NodeJS.ReadableStream) {
  const parts: Buffer[] = [];
  let size = 0;
  let cut = false;
  stream.on("data", (chunk: Buffer) => {
    if (size >= OUTPUT_CAP) {
      cut = true;
      return;
    }
    const room = OUTPUT_CAP - size;
    if (chunk.length > room) cut = true;
    parts.push(chunk.subarray(0, room));
    size += Math.min(room, chunk.length);
  });
  return { text: () => Buffer.concat(parts).toString("utf8"), truncated: () => cut };
}

/// The process and what it started (it leads its own group).
const killGroup = endCommand;
