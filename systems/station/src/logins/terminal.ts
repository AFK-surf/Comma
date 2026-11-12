// What a login command's pseudo-terminal needs of the machine: the system's `script` to give it one, and `ps` and
// `stty` to read how it stands. macOS and Linux; elsewhere a login cannot run (`terminalOf` answers null).
import { type ChildProcess, execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { platform } from "../platform/index.ts";

const MACOS = platform.os === "macos";
const quoted = (word: string) => `'${word.replaceAll("'", `'\\''`)}'`;
const run = (program: string, args: string[]): Promise<string> =>
  new Promise((resolve, reject) => execFile(program, args, (error, stdout) => (error ? reject(error) : resolve(stdout))));

export const started = (child: ChildProcess): Promise<Error | null> =>
  new Promise((resolve) => {
    child.once("spawn", () => resolve(null));
    child.once("error", (e) => resolve(e));
  });

/// The command in a terminal of `cols` by `rows`: the program and arguments to start, or null when there is no way.
export function terminalOf(program: string, args: string[], cols: number, rows: number): [string, string[]] | null {
  if (platform.os === "windows") return null;
  const sized = `stty cols ${cols} rows ${rows} 2>/dev/null; exec "$@"`;
  // macOS's script refuses a socket for its stdin, and Node's pipes are sockets: a pipe between, `cat` feeding it.
  if (MACOS) {
    const feed = `exec 3<&0; cat <&3 | { /usr/bin/script -q /dev/null /bin/sh -c '${sized}' sh "$@" 3<&-; s=$?; /usr/bin/pkill -P $$ -x cat; exit $s; }`;
    return ["/bin/sh", ["-c", feed, "sh", program, ...args]];
  }
  const script = ["/usr/bin/script", "/bin/script"].find((p) => existsSync(p));
  if (script === undefined) return null;
  return [script, ["-qfec", ["/bin/sh", "-c", sized, "sh", program, ...args].map(quoted).join(" "), "/dev/null"]];
}

/// Whether what `pid` reads is shown as typed; null when it cannot be told. A password is read a line at a time without
/// echo; a program reading keys one by one (a menu) turns off line mode too, and that is no secret.
export async function echoesOf(pid: number): Promise<boolean | null> {
  try {
    const tty = (await run("ps", ["-o", "tty=", "-p", String(pid)])).trim();
    if (tty === "" || tty.startsWith("?")) return null;
    const stty = await run("stty", [MACOS ? "-f" : "-F", `/dev/${tty}`, "-a"]);
    if (/(^|\s)-echo(\s|$)/.test(stty) && !/(^|\s)-icanon(\s|$)/.test(stty)) return false;
    return /(^|\s)-?echo(\s|$)/.test(stty) ? true : null;
  } catch {
    return null;
  }
}

export async function commandsOf(pids: number[]): Promise<string[]> {
  if (pids.length === 0) return [];
  try {
    return (await run("ps", ["-o", "comm=", "-p", pids.join(",")])).split("\n").map((l) => l.trim()).filter((l) => l !== "");
  } catch {
    return [];
  }
}

export async function descendantsOf(pid: number): Promise<number[]> {
  let text = "";
  try {
    text = await run("ps", ["-A", "-o", "pid=,ppid="]);
  } catch {
    return [];
  }
  const children = new Map<number, number[]>();
  for (const line of text.split("\n")) {
    const [child, parent] = line.trim().split(/\s+/).map(Number);
    if (!Number.isInteger(child) || !Number.isInteger(parent)) continue;
    children.set(parent!, [...(children.get(parent!) ?? []), child!]);
  }
  const out: number[] = [];
  const next = [pid];
  while (next.length > 0) {
    for (const c of children.get(next.pop()!) ?? []) {
      out.push(c);
      next.push(c);
    }
  }
  return out;
}
