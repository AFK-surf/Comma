// macOS and Linux (and another Unix as Linux): process groups and signals, /bin/sh, `/` paths, links. What the two
// differ in (how the machine reads: sysctl and vm_stat, or /proc; the keychain and QuickLook) is said here too.
import { type ChildProcess, execFile, execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { cpus as cpuList, release, type as osType } from "node:os";
import { delimiter, join } from "node:path";
import { promisify } from "node:util";
import { wall } from "../ops/fibers.ts";
import type { Env, Found, Host, Platform } from "./index.ts";
import { field, firstWord, output, parseF64, parseU64, procStatTicks, trim } from "./text.ts";

const MACOS = process.platform === "darwin";
const run = promisify(execFile);

const executable = (p: string) => {
  try {
    const st = statSync(p);
    return st.isFile() && (st.mode & 0o111) !== 0;
  } catch {
    return false;
  }
};
const real = (p: string) => {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
};

/// files.rs `clean` on Unix: the path absolute (a leading `/`), `.` and `..` worked out lexically.
function clean(path: string): string {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
}

/// When `pid` started (ms): from its elapsed time as ps says it ([[dd-]hh:]mm:ss).
function startTimeOf(pid: number): number | null {
  let text: string;
  try {
    text = execFileSync("ps", ["-o", "etime=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
  if (text === "") return null;
  let days = 0;
  let rest = text;
  const dash = text.indexOf("-");
  if (dash >= 0) {
    days = Number(text.slice(0, dash));
    rest = text.slice(dash + 1);
    if (!Number.isInteger(days)) return null;
  }
  const parts = rest.split(":").map(Number);
  if (parts.some((p) => !Number.isInteger(p))) return null;
  let seconds: number;
  if (parts.length === 3) seconds = parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
  else if (parts.length === 2) seconds = parts[0]! * 60 + parts[1]!;
  else return null;
  // ps says it on the machine's time.
  return wall.now() - (seconds + days * 86_400) * 1000;
}

const host: Host = {
  /// On macOS the CPUs' user, system, idle and nice time (os.cpus, from the same counters as Mach's
  /// HOST_CPU_LOAD_INFO, in ms rather than ticks: the share is the same); elsewhere /proc/stat.
  cpuTicks() {
    if (MACOS) {
      const all = cpuList();
      if (all.length === 0) return null;
      let [busy, total] = [0, 0];
      for (const { times: t } of all) {
        busy += t.user + t.sys + t.nice;
        total += t.user + t.sys + t.idle + t.nice;
      }
      return [busy, total];
    }
    try {
      return procStatTicks(readFileSync("/proc/stat", "utf8"));
    } catch {
      return null;
    }
  },
  /// On macOS as Activity Monitor counts it (app, wired and compressed pages, not reclaimable cache).
  memory() {
    if (MACOS) {
      const total = parseU64(output("sysctl", ["-n", "hw.memsize"]) ?? "") ?? 0;
      const vm = output("vm_stat", []);
      if (vm !== null) {
        const after = vm.split("page size of ")[1];
        const page = (after !== undefined ? parseU64(firstWord(after)) : null) ?? 16384;
        const pages = (label: string) => field(vm, label);
        const used = Math.max(pages("Anonymous pages") - pages("Pages purgeable") + pages("Pages wired down") + pages("Pages occupied by compressor"), 0) * page;
        const swapText = output("sysctl", ["-n", "vm.swapusage"]);
        const usedText = swapText?.split("used = ")[1]?.split("M")[0];
        const swapMb = usedText === undefined ? null : parseF64(usedText);
        return { totalBytes: total, usedBytes: Math.min(used, total), swapUsedBytes: swapMb === null ? null : Math.round(swapMb * 1024 * 1024) };
      }
      return { totalBytes: total, usedBytes: 0, swapUsedBytes: null };
    }
    let info = "";
    try {
      info = readFileSync("/proc/meminfo", "utf8");
    } catch {
      // None: zeros.
    }
    const kb = (k: string) => field(info, k) * 1024;
    return {
      totalBytes: kb("MemTotal"),
      usedBytes: Math.max(kb("MemTotal") - kb("MemAvailable"), 0),
      swapUsedBytes: Math.max(kb("SwapTotal") - kb("SwapFree"), 0),
    };
  },
  cpuModel() {
    if (MACOS) return output("sysctl", ["-n", "machdep.cpu.brand_string"]) ?? "";
    let info = "";
    try {
      info = readFileSync("/proc/cpuinfo", "utf8");
    } catch {
      // None: empty.
    }
    for (const l of info.split("\n")) {
      if (!l.startsWith("model name")) continue;
      const colon = l.indexOf(":", "model name".length);
      if (colon >= 0) return trim(l.slice(colon + 1));
    }
    return "";
  },
  uptimeSec() {
    if (MACOS) {
      // "{ sec = 1790000000, usec = 0 } ..."
      const text = output("sysctl", ["-n", "kern.boottime"]);
      const sec = text?.split("sec = ")[1]?.split(",")[0];
      const boot = sec === undefined ? null : /^[+-]?[0-9]+$/.test(trim(sec)) ? Number(trim(sec)) : null;
      return boot === null ? 0 : Math.max(Math.trunc(wall.now() / 1000) - boot, 0);
    }
    try {
      const s = parseF64(firstWord(readFileSync("/proc/uptime", "utf8")));
      return s === null ? 0 : Math.round(s);
    } catch {
      return 0;
    }
  },
  osName() {
    if (MACOS) {
      const version = output("sw_vers", ["-productVersion"]);
      return version !== null ? `macOS ${version}` : `macOS (Darwin ${release()})`;
    }
    return `${osType()} ${release()}`;
  },
  ownRss() {
    const kb = parseU64(trim(output("ps", ["-o", "rss=", "-p", String(process.pid)]) ?? ""));
    return kb === null ? 0 : kb * 1024;
  },
};

/// std::env::consts::OS for the Unixes Node names otherwise.
const OS: Record<string, string> = { darwin: "macos", linux: "linux", freebsd: "freebsd", openbsd: "openbsd" };

export const unix: Platform = {
  os: OS[process.platform] ?? process.platform,
  buildOs: process.platform === "darwin" || process.platform === "linux" ? process.platform : null,
  goOs: process.platform,

  exe: (name) => name,
  home: (env) => env.HOME,
  pathOf: (env) => env.PATH ?? "",
  prependPath(env, dir) {
    const rest = env.PATH ?? "";
    return { ...env, PATH: `${dir}${delimiter}${rest}` };
  },
  findCommand(name: string, env: Env): Found | null {
    const path = env.PATH;
    if (path === undefined) return null;
    for (const dir of path.split(delimiter)) {
      // An empty entry is the current directory, as split_paths has it.
      const onPath = join(dir === "" ? "." : dir, name);
      if (executable(onPath)) return { onPath, real: real(onPath) ?? onPath };
    }
    return null;
  },
  runnable: (command, args) => ({ file: command, args }),
  posixShell: () => "/bin/sh",
  powerShell(command, env) {
    const pwsh = unix.findCommand("pwsh", env);
    return pwsh ? { program: pwsh.onPath, args: ["-NoProfile", "-NonInteractive", "-Command", command] } : null;
  },
  grouped: (program, args) => [program, args],
  lowered: (program, args, by) => (by === 0 || !existsSync("/usr/bin/nice") ? [program, args] : ["/usr/bin/nice", ["-n", String(by), program, ...args]]),
  makeCommand(path, script) {
    writeFileSync(path, script);
    chmodSync(path, 0o755);
    return path;
  },

  signalGroup(pgid, signal) {
    try {
      process.kill(-pgid, signal);
    } catch {
      // ESRCH: the group is already gone.
    }
  },
  signalChildGroup(child: ChildProcess, signal) {
    try {
      if (child.pid !== undefined) process.kill(-child.pid, signal);
    } catch {
      try {
        child.kill(signal);
      } catch {}
    }
  },
  groupAlive(pgid) {
    try {
      process.kill(-pgid, 0);
      return true;
    } catch {
      return false;
    }
  },
  startTimeOf,
  groupOutlivesLeader: true,
  async groupMemory(pgids) {
    const rss = new Map<number, number>();
    try {
      const { stdout } = await run("ps", ["-axo", "pgid=,rss="]);
      for (const line of stdout.split("\n")) {
        const [pgid, kb] = line.trim().split(/\s+/).map(Number);
        if (pgid !== undefined && kb !== undefined && pgids.includes(pgid)) rss.set(pgid, (rss.get(pgid) ?? 0) + kb);
      }
    } catch {}
    return rss;
  },

  paths: {
    separator: "/",
    sep: "/",
    clean,
    key: (path) => path,
    within: (path, dir) => dir === "/" || path === dir || path.startsWith(`${dir}/`),
    isRootName: () => false,
    rooted: (path) => path.startsWith("/"),
    join: (base, given) => (given.startsWith("/") || base === "" ? given : base.endsWith("/") ? base + given : `${base}/${given}`),
    relativeIn(root, path) {
      // Path::strip_prefix: whole components of the root.
      if (path === root) return "";
      const prefix = root.endsWith("/") ? root : `${root}/`;
      return path.startsWith(prefix) ? path.slice(prefix.length) : null;
    },
    isDrivePath: () => false,
  },

  linkRefused: () => false,
  syncsDirectories: true,
  opensDirectories: true,
  modesArePrivate: true,
  shareFile(target, link) {
    try {
      const meta = lstatSync(link);
      if (meta.isSymbolicLink() && readlinkSync(link) === target) return;
      unlinkSync(link);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    symlinkSync(target, link);
  },

  runnerSocketVisible: true,
  runnerSaysLeave: false,

  host,

  isLauncher(pid) {
    try {
      const command = execFileSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      return command.includes("stillfail-station") || command.includes("ember-station");
    } catch {
      return false;
    }
  },
  async askLauncher(pid, op) {
    process.kill(pid, ({ handover: "SIGUSR2", drain: "SIGUSR1", hup: "SIGHUP" } as const)[op]);
  },
  claudeInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://claude.ai/install.sh | bash"] },
  /// In the background of a shell that ends at once: the installer is nobody's child here, and outlives both a handover
  /// (this process is let go) and a restart (the service's processes are stopped).
  startInstaller(origin, runDir, env, _app, lang) {
    const script = `( curl -fsSL "$1/install.sh?lang=$3" | sh; echo $? > "$2/update.exit" ) > "$2/update.log" 2>&1 < /dev/null &`;
    return new Promise<boolean>((resolve) => {
      const child = spawn("/bin/sh", ["-c", script, "sh", origin, runDir, lang], { env, stdio: "ignore", detached: true });
      child.on("error", () => resolve(false));
      child.on("exit", (code) => resolve(code === 0));
      child.unref();
    });
  },
  shimUpdate: () => null,
  codexStandalone: true,

  hasKeychain: MACOS,
  hasQuickLook: MACOS,
  hasFolderPermissions: MACOS,
  hasComputerUse: MACOS,
  hasWindowsComputerUse: false,
  hasHomebrew: MACOS,
};
