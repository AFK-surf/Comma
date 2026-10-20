// Windows: no process groups or signals (a job's group is the job object of the `stillfail-runner --job` it runs
// under), Git for Windows' sh for what agents write, `\` and drives in paths, links that take a privilege, PATHEXT and
// .cmd shims, a scheduled task where Unix starts things in the background.
import { type ChildProcess, execFile, execFileSync, spawn } from "node:child_process";
import { copyFileSync, existsSync, linkSync, lstatSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { cpus as cpuList, freemem, release, totalmem, uptime as osUptime, version as osVersion } from "node:os";
import { delimiter, dirname, join, win32 } from "node:path";
import { createConnection } from "node:net";
import { promisify } from "node:util";
import { pidAlive, runnerBinary } from "./processes.ts";
import type { Lang } from "../ops/i18n.ts";
import type { Env, Found, Host, Platform } from "./index.ts";
import { trim } from "./text.ts";

const run = promisify(execFile);

/// PATH as Windows spells it in an environment copied from process.env (`Path`, as often as not).
function pathOf(env: Env): string {
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH");
  return (key && env[key]) ?? "";
}

/// Where a .cmd file names `path`: cmd reads the file in the console's code page, not UTF-8, so a path with other than
/// ASCII in it (C:\Users\张三\…) is named through the variable of `env` it is under (%USERPROFILE%\…), which cmd
/// expands as it runs; none such: refused, rather than a .cmd that names some other path. (The installer's
/// stillfail.cmd: the same rule, install-windows.ts CmdPath.)
export function cmdPath(path: string, env: Env = process.env): string {
  const ascii = (s: string) => /^[\x20-\x7e]*$/.test(s);
  if (ascii(path)) return path;
  const value = (name: string) => {
    const key = Object.keys(env).find((k) => k.toUpperCase() === name.toUpperCase());
    return key ? env[key]?.replace(/[\\/]+$/, "") : undefined;
  };
  const under = CMD_PATH_VARS.flatMap((name) => {
    const dir = value(name);
    if (!dir) return [];
    const rest = path.slice(dir.length);
    return path.slice(0, dir.length).toLowerCase() === dir.toLowerCase() && /^([\\/]|$)/.test(rest) && ascii(rest) ? [{ name, dir, rest }] : [];
  });
  const best = under.sort((a, b) => b.dir.length - a.dir.length)[0];
  if (!best) throw new Error(`a .cmd cannot name ${path}: it has other than ASCII in it, outside the user's folders`);
  return `%${best.name}%${best.rest}`;
}

const CMD_PATH_VARS = ["USERPROFILE", "LOCALAPPDATA", "APPDATA", "TEMP", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "PUBLIC"];

const real = (p: string) => {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
};
const isFile = (p: string) => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

/// A command is a file with one of PATHEXT's extensions (no mode bit says it runs): `codex` is found as `codex.cmd`,
/// `claude` as `claude.exe`.
function findCommand(name: string, env: Env): Found | null {
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH");
  const path = key === undefined ? undefined : env[key];
  if (path === undefined) return null;
  const exts = (env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";").filter((e) => e !== "").map((e) => e.toLowerCase());
  for (const dir of path.split(delimiter)) {
    for (const ext of exts) {
      const onPath = join(dir === "" ? "." : dir, name + ext);
      if (isFile(onPath)) return { onPath, real: real(onPath) ?? onPath };
    }
  }
  return null;
}

let shell: string | null | undefined;

/// CLAUDE_CODE_GIT_BASH_PATH (Claude Code's own setting), else Git's sh beside the git on PATH, else where Git installs
/// by default; never System32's bash (WSL's, another machine's files). Where the machine has it is the station's own
/// environment's to say too: a command's own may name no Git (the connector's, a test's). Looked for again until found,
/// so a Git installed meanwhile is taken.
function posixShell(env: NodeJS.ProcessEnv = process.env): string {
  if (!shell) shell = gitShell(env) ?? (env === process.env ? null : gitShell(process.env));
  if (shell === null) throw new Error("jobs and commands on Windows run under Git Bash: install Git for Windows (git-scm.com), or set CLAUDE_CODE_GIT_BASH_PATH");
  return shell;
}

function gitShell(env: NodeJS.ProcessEnv): string | null {
  const candidates: string[] = [];
  if (env.CLAUDE_CODE_GIT_BASH_PATH) candidates.push(env.CLAUDE_CODE_GIT_BASH_PATH);
  for (const dir of pathOf(env).split(delimiter)) {
    if (dir === "" || /\\system32\\?$/i.test(dir)) continue;
    // Git's cmd\ (git.exe) is what an installer puts on PATH; its sh is in bin\.
    if (existsSync(join(dir, "git.exe"))) candidates.push(join(dirname(dir), "bin", "sh.exe"));
    candidates.push(join(dir, "sh.exe"));
  }
  for (const root of [env.ProgramFiles, env["ProgramFiles(x86)"], env.LOCALAPPDATA && join(env.LOCALAPPDATA, "Programs")]) {
    if (root) candidates.push(join(root, "Git", "bin", "sh.exe"));
  }
  return candidates.find((p) => existsSync(p)) ?? null;
}

/// What a `.cmd` shim runs when its arguments can go around cmd (as the runner's `unshim`, native/runner): npm's
/// (`"%_prog%" "%dp0%\…\cli.js" %*`) as Node and the script; one that only hands on to another `.cmd` (Vite+'s) as
/// what that one runs. Null for anything else.
export function unshim(path: string, env: NodeJS.ProcessEnv = process.env): { node: string; script: string } | null {
  for (let i = 0; i < 4; i++) {
    if (!/\.cmd$/i.test(path)) return null;
    let text: string;
    try {
      const st = statSync(path);
      if (!st.isFile() || st.size > 16 * 1024) return null;
      text = readFileSync(path, "utf8");
    } catch {
      return null;
    }
    const dir = dirname(path);
    const npm = text.match(/"%_prog%"\s+"%dp0%\\([^"]+)"\s+%\*/);
    if (npm) {
      const beside = join(dir, "node.exe");
      const node = existsSync(beside) ? beside : (findCommand("node", env)?.onPath ?? "node");
      return { node, script: join(dir, npm[1]!) };
    }
    const lines = text
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l !== "" && l.toLowerCase() !== "@echo off" && !l.toLowerCase().startsWith("exit /b"));
    const on = lines.length === 1 ? lines[0]!.match(/^"([^"]+)"\s+%\*$/) : null;
    if (!on) return null;
    path = on[1]!;
  }
  return null;
}

/// A job's group is its runner: any signal ends it, and its job with it.
function signalGroup(pgid: number) {
  try {
    process.kill(pgid, "SIGKILL");
  } catch {
    // ESRCH: already gone.
  }
}

/// When `pid` started, as Windows records it (to the millisecond).
function startTimeOf(pid: number): number | null {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const text = execFileSync(
      "powershell",
      ["-NoProfile", "-NonInteractive", "-Command", `(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')`],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], windowsHide: true },
    ).trim();
    const at = Date.parse(text);
    return Number.isNaN(at) ? null : at;
  } catch {
    return null;
  }
}

/// A group is its leader's process tree (a runner's job holds no other): each leader's working set and its
/// descendants', from Win32_Process (kB).
async function groupMemory(pgids: number[]): Promise<Map<number, number>> {
  const rss = new Map<number, number>();
  try {
    const script = "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId) $($_.WorkingSetSize)\" }";
    const { stdout } = await run("powershell", ["-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true, maxBuffer: 16 << 20 });
    const children = new Map<number, number[]>();
    const bytes = new Map<number, number>();
    for (const line of stdout.split(/\r?\n/)) {
      const [pid, parent, size] = line.trim().split(/\s+/).map(Number);
      if (!Number.isInteger(pid) || !Number.isInteger(parent) || !Number.isFinite(size)) continue;
      bytes.set(pid!, size!);
      if (pid !== parent) children.set(parent!, [...(children.get(parent!) ?? []), pid!]);
    }
    for (const pgid of pgids) {
      if (!bytes.has(pgid)) continue;
      let total = 0;
      const seen = new Set<number>();
      for (const queue = [pgid]; queue.length > 0; ) {
        const pid = queue.pop()!;
        if (seen.has(pid)) continue;
        seen.add(pid);
        total += bytes.get(pid) ?? 0;
        queue.push(...(children.get(pid) ?? []));
      }
      rss.set(pgid, Math.round(total / 1024));
    }
  } catch {}
  return rss;
}

const key = (path: string) => path.toLowerCase();

const sameFile = (a: string, b: string) => {
  try {
    const [x, y] = [statSync(a, { bigint: true }), statSync(b, { bigint: true })];
    return x.ino === y.ino && x.dev === y.dev;
  } catch {
    return false;
  }
};

/// What Node's os says (the same counters Task Manager reads): Windows has neither /proc nor sysctl.
const host: Host = {
  cpuTicks() {
    const all = cpuList();
    if (all.length === 0) return null;
    let [busy, total] = [0, 0];
    for (const { times: t } of all) {
      busy += t.user + t.sys + t.nice;
      total += t.user + t.sys + t.idle + t.nice;
    }
    return [busy, total];
  },
  memory: () => ({ totalBytes: totalmem(), usedBytes: Math.max(totalmem() - freemem(), 0), swapUsedBytes: null }),
  cpuModel: () => trim(cpuList()[0]?.model ?? ""),
  uptimeSec: () => Math.round(osUptime()),
  // "Windows 11 Pro 10.0.26300", not os.type()'s "Windows_NT".
  osName: () => `${osVersion()} ${release()}`,
  ownRss: () => process.memoryUsage.rss(),
};

/// A PowerShell string of `s`.
const q = (s: string) => `'${s.replaceAll("'", "''")}'`;

/// run/update.ps1 (startInstaller): the STILLFAIL_ (and EMBER_DATA) variables of `env`, then the cloud's install.ps1
/// fetched into run/ and run, what it says (both streams, UTF-8) in run/update.log and its exit in run/update.exit, then
/// `task` removed. With a BOM, as PowerShell 5.1 reads a file of non-ASCII words.
export function windowsUpdateScript(origin: string, runDir: string, env: Record<string, string>, task: string, lang: Lang): string {
  return String.fromCharCode(0xfeff) + `${[
    ...Object.entries(env).filter(([k]) => k.startsWith("STILLFAIL_") || k === "EMBER_DATA").map(([k, v]) => `$env:${k} = ${q(v)}`),
    "[Console]::OutputEncoding = [Text.Encoding]::UTF8",
    `$run = ${q(runDir)}`,
    "$log = Join-Path $run 'update.log'",
    "$err = Join-Path $run 'update.err'",
    "$code = 1",
    "try {",
    `  $script = Invoke-RestMethod -UseBasicParsing ${q(`${origin}/install.ps1?lang=${lang}`)}`,
    "  [IO.File]::WriteAllText((Join-Path $run 'install.ps1'), $script, (New-Object Text.UTF8Encoding $true))",
    `  $p = Start-Process (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $run 'install.ps1') + '"') -RedirectStandardOutput $log -RedirectStandardError $err -NoNewWindow -PassThru`,
    "  $null = $p.Handle",
    "  $p.WaitForExit()",
    "  $code = $p.ExitCode",
    "  $said = Get-Content -LiteralPath $err -Raw -Encoding UTF8",
    "  if ($said) { Add-Content -LiteralPath $log -Value $said -Encoding UTF8 }",
    "} catch { Add-Content -LiteralPath $log -Value ($_ | Out-String) -Encoding UTF8 }",
    "Set-Content -LiteralPath (Join-Path $run 'update.exit') -Value $code -Encoding ASCII",
    `try { Unregister-ScheduledTask -TaskName ${q(task)} -Confirm:$false -ErrorAction Stop } catch {}`,
  ].join("\r\n")}\r\n`;
}

/// By a scheduled task of its own ("<the station's task> update"): nobody's child here, with no window
/// (`stillfail-station-w --run`, copied into run/ so the installer stopping what runs from <app> leaves it be). (Not
/// WMI's Win32_Process.Create: PowerShell started so is what malware does, and security software refuses it.) The task
/// starts with the user's own environment, so what this side gives it is in run/update.ps1 (windowsUpdateScript).
function startInstaller(origin: string, runDir: string, env: Record<string, string>, app: string, lang: Lang): Promise<boolean> {
  const ps1 = join(runDir, "update.ps1");
  const hidden = join(runDir, "stillfail-update-w.exe");
  // The station's task as install.ps1 named it (windows.json: a station apart's), and " update".
  let task = "still.fail station";
  try {
    const kept = JSON.parse(readFileSync(join(dirname(runDir), "windows.json"), "utf8").trim());
    if (typeof kept?.task === "string" && kept.task) task = kept.task;
  } catch {}
  task += " update";
  try {
    rmSync(join(runDir, "update.err"), { force: true });
    // Refused while an update before still runs from it.
    copyFileSync(join(app, "mesh", "target", "release", "stillfail-station-w.exe"), hidden);
    writeFileSync(ps1, windowsUpdateScript(origin, runDir, env, task, lang));
  } catch {
    return Promise.resolve(false);
  }
  const register = [
    "$ErrorActionPreference = 'Stop'",
    "$ps = (Get-Process -Id $PID).Path",
    `$action = New-ScheduledTaskAction -Execute ${q(hidden)} -Argument ('--run "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ${q(ps1)} + '"') -WorkingDirectory ${q(runDir)}`,
    "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew",
    "$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited",
    `Register-ScheduledTask -TaskName ${q(task)} -Action $action -Settings $settings -Principal $principal -Force | Out-Null`,
    `Start-ScheduledTask -TaskName ${q(task)}`,
  ].join("\r\n");
  return new Promise<boolean>((resolve) => {
    const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(register, "utf16le").toString("base64")], {
      env, stdio: "ignore", windowsHide: true,
    });
    child.on("error", () => resolve(false));
    child.on("exit", (code) => resolve(code === 0));
  });
}

export const windows: Platform = {
  os: "windows",
  buildOs: "win32",
  goOs: "windows",

  exe: (name) => `${name}.exe`,
  home: (env) => env.HOME ?? env.USERPROFILE,
  pathOf,
  /// The variable is one whatever its case: the others are dropped, so a child is not given two.
  prependPath(env, dir) {
    const rest = pathOf(env);
    const out: NodeJS.ProcessEnv = {};
    for (const [k, v] of Object.entries(env)) if (k.toUpperCase() !== "PATH") out[k] = v;
    out.PATH = `${dir}${delimiter}${rest}`;
    return out;
  },
  findCommand,
  /// A bare name is found with PATHEXT (libuv adds .exe and .com only), and a .cmd or .bat (npm's shims) runs through
  /// cmd, which Node refuses to do by itself: each argument quoted, and one cmd would read into (a quote, a %) refused.
  runnable(command, args, env) {
    const file = /[\\/]/.test(command) ? command : (findCommand(command, env)?.onPath ?? command);
    if (!/\.(cmd|bat)$/i.test(file)) return { file, args };
    const shim = unshim(file, env);
    if (shim !== null) return { file: shim.node, args: [shim.script, ...args] };
    for (const a of [file, ...args]) if (/["%\r\n]/.test(a)) throw new Error(`cannot pass ${JSON.stringify(a)} through cmd`);
    const line = [file, ...args].map((a) => `"${a}"`).join(" ");
    return { file: env.ComSpec ?? process.env.ComSpec ?? "cmd.exe", args: ["/d", "/s", "/c", `"${line}"`], windowsVerbatimArguments: true };
  },
  posixShell,
  /// As -EncodedCommand (UTF-16LE): no quoting of Node's or cmd's comes between the command and PowerShell. 5.1 writes
  /// its output in the console's code page (GBK on a Chinese Windows) unless told UTF-8 first.
  powerShell(command, env) {
    const pwsh = findCommand("pwsh", env)?.onPath;
    const program = pwsh ?? join(env.SystemRoot ?? env.SYSTEMROOT ?? "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    const script = `[Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8\n${command}`;
    return { program, args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")] };
  },
  /// Under `stillfail-runner --job`, whose job holds the command and all it starts (what a shell execs, its parent
  /// gone, too), ended whole when the runner is.
  grouped: (program, args) => [runnerBinary(), ["--job", "--", program, ...args]],
  lowered: (program, args) => [program, args],
  /// Windows runs no script by its #!: a .cmd beside it hands it to Git's sh (or does nothing).
  makeCommand(path, script, noop) {
    writeFileSync(path, script);
    const name = path.slice(Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/")) + 1);
    // %~dp0 is cmd's to expand (any path); the shell's is named as a .cmd can (cmdPath).
    writeFileSync(`${path}.cmd`, noop ? "@exit /b 0\r\n" : `@"${cmdPath(posixShell())}" "%~dp0${name}" %*\r\n`);
    return `${path}.cmd`;
  },

  signalGroup: (pgid) => signalGroup(pgid),
  signalChildGroup(child: ChildProcess) {
    if (child.pid !== undefined) signalGroup(child.pid);
  },
  groupAlive: (pgid) => pidAlive(pgid),
  startTimeOf,
  // A leader gone leaves nothing to know its tree by.
  groupOutlivesLeader: false,
  groupMemory,

  paths: {
    separator: /[\\/]/,
    sep: "\\",
    // One with no drive is on the current one, and nothing given is the drive's root.
    clean: (path) => win32.resolve(path === "" ? "\\" : path),
    key,
    within(path, dir) {
      const [p, d] = [key(path), key(dir)];
      return p === d || p.startsWith(/[\\/]$/.test(d) ? d : `${d}\\`);
    },
    isRootName: (part) => /^[A-Za-z]:$/.test(part),
    rooted: (path) => path.startsWith("/") || win32.isAbsolute(path) || path.includes(":"),
    join: (base, given) => (win32.isAbsolute(given) || base === "" ? given : /[\\/]$/.test(base) ? base + given : `${base}\\${given}`),
    relativeIn(root, path) {
      // Whole components, as Windows compares them (case aside, either separator).
      const within = win32.relative(root, path);
      return within.startsWith("..") || win32.isAbsolute(within) ? null : within;
    },
    isDrivePath: (text) => /^[A-Za-z]:[\\/]/.test(text),
  },

  linkRefused: (error) => (error as NodeJS.ErrnoException).code === "EPERM",
  syncsDirectories: false,
  opensDirectories: false,
  modesArePrivate: false,
  /// A symbolic link needs a privilege most users lack (Developer Mode gives it): a hard link then, the same file as
  /// long as it is written in place (seen of Codex 0.162.1 on Windows, 2026-10-10: `codex login --with-api-key` into a
  /// home whose auth.json was a hard link kept the link, both names the new file; its refresh is taken to save the same
  /// way).
  shareFile(target, link) {
    try {
      const meta = lstatSync(link);
      if (meta.isSymbolicLink() && readlinkSync(link) === target) return;
      if (sameFile(link, target)) return;
      unlinkSync(link);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    try {
      symlinkSync(target, link);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EPERM") throw error;
      linkSync(target, link);
    }
  },

  // A pipe is not a file: looking at it is a connection (the runner serves one at a time).
  runnerSocketVisible: false,
  runnerSaysLeave: true,

  host,

  isLauncher(pid) {
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try {
      const name = execFileSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", `(Get-Process -Id ${pid} -ErrorAction Stop).ProcessName`], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], windowsHide: true,
      }).trim();
      return /^(stillfail|ember)-station(-w)?$/i.test(name);
    } catch {
      return false;
    }
  },
  /// No signals (one sent ends the process): a line on the launcher's own pipe (launcher/src/run_windows.rs
  /// `control_pipe`), which only this user may open.
  askLauncher(pid, op) {
    return new Promise<void>((resolve, reject) => {
      const pipe = createConnection(`\\\\.\\pipe\\stillfail-launcher-${pid}`);
      pipe.once("error", reject);
      pipe.once("connect", () => pipe.end(`${JSON.stringify({ op })}\n`));
      pipe.once("close", (failed) => (failed ? undefined : resolve()));
    });
  },
  /// Claude Code's own installer on Windows (into ~\.local\bin), as its documentation gives it.
  claudeInstall: {
    program: "powershell",
    args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex"],
  },
  startInstaller,
  /// Vite+'s command is a shim of its own (codex.cmd, codex.exe) beside vp.exe; npm's a .cmd in its global prefix,
  /// the package in node_modules beside it.
  shimUpdate(found, pkg, env) {
    const dir = dirname(found.onPath);
    if (existsSync(join(dir, "vp.exe"))) return { program: join(dir, "vp.exe"), args: ["install", "-g", `${pkg}@latest`] };
    if (/\.cmd$/i.test(found.onPath) && existsSync(join(dir, "node_modules", ...pkg.split("/")))) {
      const own = join(dir, "npm.cmd");
      const npm = existsSync(own) ? own : findCommand("npm", env)?.onPath;
      return npm === undefined ? "no-npm" : { program: npm, args: ["install", "-g", `${pkg}@latest`, "--prefix", dir] };
    }
    return null;
  },
  // Its installer is a shell script (install.sh).
  codexStandalone: false,

  hasKeychain: false,
  hasQuickLook: false,
  hasFolderPermissions: false,
  hasComputerUse: false,
  hasHomebrew: false,
};
