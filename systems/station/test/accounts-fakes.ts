// What the accounts' tests stand in for: providers (a local HTTP server answering as a test says, keeping what it was
// asked), command-line tools (shell scripts in a bin/ of a temp HOME, first on a PATH of only that and the system's),
// and a machine (a temp HOME with its own .claude and .codex). Nothing here reaches a real service, keychain or login.
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { WINDOWS, platform } from "../src/platform/index.ts";

/// A stand-in's test that a variable names a path under its HOME: `sameAs("CODEX_HOME", "cx")`. Git's sh (Windows)
/// has HOME in a form of its own (/tmp/…, /c/…), so both are compared as Windows has them there.
export const sameAs = (variable: string, under: string) =>
  `p() { [ -x /usr/bin/cygpath ] && /usr/bin/cygpath -m "$1" || echo "$1"; }; [ "$(p "$${variable}")" = "$(p "$HOME/${under}")" ]`;

/// What runs a stand-in made by `script` at `path`: itself, on Windows its .cmd.
export const exe = (path: string) => (WINDOWS ? `${path}.cmd` : path);

export type Asked = { method: string; url: string; headers: Record<string, string>; body: any };
export type Reply = { status: number; body: unknown; delayMs?: number };

/// A provider at a local address: `answer` says what each request gets; `asked` keeps the requests in order.
export async function provider(answer: (asked: Asked) => Reply) {
  const asked: Asked[] = [];
  const server = createServer(async (req: IncomingMessage, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const text = Buffer.concat(chunks).toString("utf8");
    let body: any = null;
    try {
      body = text === "" ? null : JSON.parse(text);
    } catch {}
    const one: Asked = { method: req.method ?? "", url: req.url ?? "", headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)])), body };
    asked.push(one);
    const reply = answer(one);
    if (reply.delayMs) await new Promise((r) => setTimeout(r, reply.delayMs));
    const out = typeof reply.body === "string" ? reply.body : JSON.stringify(reply.body);
    res.writeHead(reply.status, { "content-type": "application/json", connection: "close" });
    res.end(out);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const base = `http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}`;
  return { base, asked, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

export const temp = (name: string) => mkdtempSync(join(tmpdir(), `accounts-${name}-`));

/// A machine: a HOME, and a bin/ with stand-ins for the CLIs (shell scripts) on a PATH of only that and the system's.
/// A `security` that finds nothing of Claude Code's unless one is given (never the real keychain).
export function machine(clis: Record<string, string> = {}): { home: string; bin: string; env: Record<string, string> } {
  const home = temp("machine");
  const bin = join(home, "bin");
  mkdirSync(bin);
  for (const [name, text] of Object.entries({ security: "exit 44", ...clis })) script(join(bin, name), text.startsWith("#!") ? text : `#!/bin/sh\n${text}\n`);
  return { home, bin, env: { HOME: home, PATH: WINDOWS ? `${bin};${process.env.SystemRoot ?? "C:\\Windows"}\\System32` : `${bin}:/usr/bin:/bin` } };
}

/// macOS looks at every new executable file the first time it runs (some 200 ms each, more on a busy machine), and the
/// stand-ins are new files in new temp homes. So a shell stand-in is a hard link to one launcher, made once per machine
/// (and looked at once), that runs the stand-in's text kept beside it: `<path>.sh`, or beside the file `<path>` links to.
/// Toward the code under test it is the same: an executable file at `path` that does what `text` says. Other
/// interpreters' scripts are written as they are.
const LAUNCHER = `#!/bin/sh
# A test's stand-in command (test/accounts-fakes.ts): runs the shell script beside it.
s="$0.sh"
[ -f "$s" ] || s="$(/bin/realpath "$0").sh"
exec /bin/sh "$s" "$@"
`;

/// The launcher shared by the stand-ins (made once, never written again: stand-ins are links to it).
export function launcher(): string {
  const path = join(tmpdir(), "station-test-launcher-1");
  if (existsSync(path)) return path;
  const made = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}`;
  writeFileSync(made, LAUNCHER, { mode: 0o755 });
  try {
    linkSync(made, path);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
  } finally {
    rmSync(made, { force: true });
  }
  return path;
}

/// An executable script at `path`: a shell script by the shared launcher, another as it is. On Windows, which runs
/// nothing by its #!, `<path>.cmd` (what a shell finds for `path`'s name) runs it: a shell script with Git's sh, another
/// with its interpreter (the last word of its #!).
export function script(path: string, text: string) {
  if (WINDOWS) {
    const name = basename(path);
    const first = text.startsWith("#!") ? text.slice(2, text.indexOf("\n")).trim().split(/\s+/) : ["/bin/sh"];
    const sh = first[0] === "/bin/sh" || first.at(-1) === "sh";
    writeFileSync(`${path}.sh`, sh ? text : "");
    if (!sh) writeFileSync(path, text);
    const run = sh ? `"${platform.posixShell()}" "%~dp0${name}.sh"` : `"${first.at(-1)}" "%~dp0${name}"`;
    writeFileSync(`${path}.cmd`, `@${run} %*\r\n`);
    return;
  }
  // Never written through: an earlier stand-in at `path` is the launcher's link.
  rmSync(path, { force: true });
  if (text.startsWith("#!") && !text.startsWith("#!/bin/sh\n")) {
    writeFileSync(path, text);
    chmodSync(path, 0o755);
    return;
  }
  writeFileSync(`${path}.sh`, text);
  try {
    linkSync(launcher(), path);
  } catch {
    // Another file system than the launcher's: a copy (looked at the first time it runs).
    writeFileSync(path, LAUNCHER);
    chmodSync(path, 0o755);
  }
}

/// An approval a stand-in waits for (a fifo it reads a line from): `approve` lets it go on.
export function approval(dir: string): { path: string; approve: () => Promise<void> } {
  const path = join(dir, `approval-${Math.random().toString(36).slice(2)}`);
  // Windows has no fifos: the stand-in waits for the file instead (fakeLogin).
  if (!WINDOWS) execFileSync("/usr/bin/mkfifo", [path]);
  return { path, approve: () => writeFile(path, "approved\n") };
}

/// The stand-in login command (login.rs's tests): Claude's prints a link and reads a code; Codex's prints a device
/// link and a code, then finishes once the person approved (when an `approval` fifo is given, once it is written).
export const fakeLogin = (approval?: string) => `#!/bin/sh
if [ "$1" = "auth" ]; then
  echo "Opening browser to sign in…"
  echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y"
  printf "Paste code here if prompted > "
  read code
  [ "$code" = "good-code" ] && { echo "Login successful"; exit 0; }
  echo "OAuth error: invalid code"; exit 1
fi
printf "1. Open this link\\n   \\033[94mhttps://auth.openai.com/codex/device\\033[0m\\n2. Enter this one-time code\\n   \\033[94mABCD-12345\\033[0m\\n"
${approval === undefined ? "" : `while [ ! -e '${approval}' ]; do sleep 0.05; done; read approved < '${approval}'`}
echo "Successfully logged in"
`;

/// Waits until `f` gives something, looking again each time `changes` says something changed. No deadline: what is
/// waited for happens or the test hangs (and node --test's own timeout ends it), whatever the machine's speed.
export function upon<T>(changes: (wake: () => void) => () => void, f: () => T | undefined | null | false | Promise<T | undefined | null | false>, _what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let over = false;
    let looking = false;
    let again = false;
    const finish = (then: () => void) => {
      if (over) return;
      over = true;
      stop();
      then();
    };
    const look = async () => {
      if (over) return;
      if (looking) return void (again = true);
      looking = true;
      try {
        do {
          again = false;
          const got = await f();
          if (got) return finish(() => resolve(got));
        } while (again && !over);
      } catch (e) {
        finish(() => reject(e));
      } finally {
        looking = false;
      }
    };
    const stop = changes(() => void look());
    void look();
  });
}

/// Waits until `f` gives something, looking every 20 ms. No deadline, as `upon`.
export async function until<T>(f: () => T | undefined | null | false | Promise<T | undefined | null | false>, _what: string): Promise<T> {
  for (;;) {
    const got = await f();
    if (got) return got;
    await new Promise((r) => setTimeout(r, 20));
  }
}

export const idToken = (claims: unknown) => `x.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.y`;
