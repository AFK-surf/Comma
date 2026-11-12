// The `login` tool of a Task's sandbox: a command-line tool is not logged in, and its own login command runs here in a
// pseudo-terminal (run.ts). The agent answers its prompts. A person does only the step that needs them, on a card in the
// Task (Salix's `oauth.login_card`): a device code to confirm, or a page whose code they paste back. The call waits for
// them. A sandbox's disk may be lost, so the files a finished login wrote are kept with Salix for the Task's person
// (`task.login_keep`) and put back when that person's Task next needs them (`task.login_restore`): neither goes through a
// tool call, so nothing kept reaches the agent or a tool's archive. Nothing types a secret: a prompt read without echo is
// refused.
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { commandWords, programOf } from "./command-output.ts";
import { type Key, LoginRun } from "./run.ts";
import type { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import type { Tool } from "../tools/mcp.ts";

type Json = any;

/// What a login needs of its Task on Salix.
export type LoginHost = {
  offered(session: string): boolean;
  call(session: string, tool: string, args: Record<string, unknown>): Promise<Json>;
  keep(session: string, program: string, archive: string): Promise<Json>;
  restore(session: string, program: string): Promise<Json>;
  /// Tells a session's agent something when no call of its is waiting: it runs again on hearing it.
  notify(session: string, text: string): Promise<void>;
  /// Whether a turn of the session's agent is running now.
  running(session: string): boolean;
};

/// How long a call waits for the command to go quiet, and for the person (the call's own deadline is a little longer).
const SETTLE_MS = 15_000;
const PERSON_MS = 14 * 60_000;
/// What a login's files may come to, as Salix keeps a value (base64 of a gzip).
const MAX_KEPT_BYTES = 60_000;
const MAX_KEPT_FILE = 256 * 1024;
const MAX_KEPT_FILES = 40;
/// Under the home directory, what is never a login's: caches, packages and the agents' own.
const NOT_LOGINS = new Set([".cache", ".npm", ".pnpm-store", ".cargo", ".rustup", ".local", ".claude", ".codex", ".comma", "node_modules", "Library", "workspace", "repos", ".git"]);
const KEYS: Record<string, Key> = { enter: "Enter", backspace: "Backspace", up: "Up", down: "Down", left: "Left", right: "Right", tab: "Tab", "ctrl-c": "Ctrl-C" };

export const LOGIN_DESCRIPTION =
  "Log this sandbox in to a command-line tool that needs its own login: use it only when the tool takes no token (a credential you can get with oauth.request_authorization and pass with comma exec is better, since it survives a lost disk). command: its own login command, preferring its device-code or browser way (gh auth login --web -h github.com --insecure-storage, az login --use-device-code, aws sso login --use-device-code, wrangler login --device, gcloud auth login --no-launch-browser, docker login, npm login); reason says why, in the person's language. An earlier login of that person is put back first: try your command again, and only if it still fails call again with fresh: true. Answer the command's prompts yourself with id, input and key. If its screen says the page gives a code to paste back, call with id and paste: true. The person's step is on a card in this Task, and the call returns when they finish or the command needs you again. Never ask for a password, a token or a code in the chat, and never send them to a terminal. A prompt read without echo takes nothing: cancel, and use another way.";

type Entry = {
  run: LoginRun;
  session: string;
  reason: string;
  program: string;
  card: boolean;
  since: number;
  /// What it came to, once it ended: its card closed and its files kept, whoever was or was not waiting.
  ended?: Promise<string>;
  /// A call of its agent is waiting for it (`#until`), and says how it ended if its turn still runs.
  waited: boolean;
};

/// Lines of its screen as the agent reads them, with the page's address and the code hidden: it has no use for them.
function screenOf(entry: Entry): string {
  const { run } = entry;
  const hide = (line: string) => {
    const out = line.replace(/https?:\/\/\S+/g, "<link>");
    return (run.code ? out.split(run.code).join("<code>") : out).trimEnd();
  };
  return run.screen().rows.map(hide).filter((line) => line !== "").slice(-30).join("\n");
}

/// Files under `dir` changed since `since`, stopping at what is never a login's.
function changedFiles(dir: string, since: number, found: string[], depth = 0): void {
  if (depth > 6 || found.length > MAX_KEPT_FILES) return;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (NOT_LOGINS.has(entry.name)) continue;
    // Beside the home directory's hidden directories and its top-level dotfiles, nothing is a login's.
    if (depth === 0 && !entry.name.startsWith(".")) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      changedFiles(path, since, found, depth + 1);
    } else if (entry.isFile()) {
      const stat = statSync(path);
      if (stat.mtimeMs >= since && stat.size <= MAX_KEPT_FILE) found.push(path);
    }
  }
}

const tar = (args: string[]): Promise<Buffer> =>
  new Promise((resolve, reject) =>
    execFile("tar", args, { encoding: "buffer", maxBuffer: 4 * MAX_KEPT_BYTES }, (error, stdout) => (error ? reject(error) : resolve(stdout))),
  );

export class Logins {
  readonly #entries = new Map<string, Entry>();
  readonly #host: LoginHost;
  readonly #fibers: Fibers;
  readonly #data: string;
  #next = 0;

  readonly #personMs: number;

  constructor(host: LoginHost, fibers: Fibers, data: string, personMs = PERSON_MS) {
    this.#host = host;
    this.#fibers = fibers;
    this.#data = data;
    this.#personMs = personMs;
  }

  tools(): Tool[] {
    return [
      {
        name: "login",
        description: LOGIN_DESCRIPTION,
        inputSchema: {
          type: "object",
          properties: {
            command: { description: "Start: the tool's own login command, as a line.", anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
            reason: { type: "string", description: "With command: why it is needed, for the person, in their language." },
            fresh: { type: "boolean", description: "With command: the earlier login put back did not work; log in anew." },
            id: { type: "string", description: "A login's id: how it stands; with input, key, paste or cancel, act on it." },
            input: { type: "string", description: "With id: text typed at its prompt." },
            key: { type: "string", enum: Object.keys(KEYS), description: "With id: a key pressed, after input." },
            paste: { type: "boolean", description: "With id: its page gives a code to paste back: the person enters it on the card." },
            cancel: { type: "boolean", description: "With id: end it." },
          },
          additionalProperties: false,
        },
        offered: (session) => this.#host.offered(session),
        run: (session, args) => this.#act(session, args),
      },
    ];
  }

  /// What a person did on a request's card (Salix's `task.login_answer`).
  answer(params: Json): Json {
    const entry = this.#entries.get(String(params?.login ?? ""));
    if (!entry || !entry.run.active) return { error: "no_such_login" };
    if (params.cancel === true) {
      entry.run.cancel();
      return { ok: true };
    }
    if (typeof params.value !== "string" || !entry.run.paste || entry.run.secret) return { error: "not_waiting" };
    entry.run.input({ text: params.value.trim() });
    entry.run.input({ key: "Enter" });
    entry.run.answeredNow();
    return { ok: true };
  }

  async #act(session: string, args: Record<string, unknown>): Promise<string> {
    if (args.command !== undefined) return await this.#start(session, args);
    const entry = this.#entries.get(String(args.id ?? ""));
    if (!entry || entry.session !== session) throw new Error("No such login. Start one with command.");
    if (args.cancel === true) entry.run.cancel();
    else if (args.paste === true) entry.run.askPaste(true);
    else if (typeof args.input === "string" || typeof args.key === "string") {
      if (entry.run.secret) throw new Error("It asks for a secret, read without echo: nothing is typed there. Cancel it, and use the tool's browser or device-code way.");
      const key = typeof args.key === "string" ? KEYS[args.key] : undefined;
      const quiet = entry.run.nextQuiet();
      entry.run.input({ ...(typeof args.input === "string" ? { text: args.input } : {}), ...(key ? { key } : {}) });
      await this.#within(quiet, SETTLE_MS);
    }
    return await this.#told(entry);
  }

  async #start(session: string, args: Record<string, unknown>): Promise<string> {
    const words = Array.isArray(args.command) ? args.command.map(String) : commandWords(String(args.command));
    if (!words || words.length === 0) throw new Error("command is the tool's own login command.");
    const home = platform.home(process.env);
    // Run with no shell in between, so a home-relative command is spelled out here.
    if (home && words[0]!.startsWith("~/")) words[0] = join(home, words[0]!.slice(2));
    const program = programOf(words);
    if (typeof args.reason !== "string" || args.reason.trim() === "") throw new Error("reason says why it is needed, for the person.");
    if (args.fresh !== true && (await this.#restored(session, program, home))) {
      return `An earlier login of this person to ${program} was put back. Run your command again. If it still is not logged in, call again with fresh: true.`;
    }
    const running = [...this.#entries.values()].find((e) => e.session === session && e.run.active && e.run.command.join("\0") === words.join("\0"));
    if (running) return await this.#told(running);
    const id = `${this.#fibers.now().toString(36)}${(++this.#next).toString(36)}`;
    const dir = join(this.#data, "run", "logins");
    mkdirSync(dir, { recursive: true });
    const entry: Entry = { session, reason: args.reason.trim(), program, card: false, waited: false, since: Date.now() - 1_000, run: undefined as unknown as LoginRun };
    entry.run = new LoginRun({
      id,
      command: words,
      env: process.env as Record<string, string>,
      cwd: home ?? dir,
      shims: this.#shims(),
      opened: join(dir, `${id}.opened`),
      fibers: this.#fibers,
      changed: () => {
        if (entry.run.active) return;
        const told = this.#finished(entry);
        // An agent can end its turn with its call still open (it posts that it waits): then nothing hears the call's answer.
        if (!entry.waited || !this.#host.running(session)) void told.then((text) => this.#host.notify(session, `Your login of ${program} ended. ${text}`)).catch((error) => log.warn("logins", "its end was not told", { error: (error as Error).message }));
      },
      drawn: () => {},
    });
    this.#entries.set(id, entry);
    const quiet = entry.run.nextQuiet();
    await entry.run.start();
    await this.#within(quiet, SETTLE_MS);
    return await this.#told(entry);
  }

  /// How it stands, as its agent is told; a person's step puts the card up and waits for them.
  async #told(entry: Entry): Promise<string> {
    const { run } = entry;
    if (run.active && run.step === "loopback" && !run.paste) {
      run.cancel();
      return `It needs its page to call back to this sandbox, which a person's browser cannot reach, so it was ended. Use the tool's device-code or code-to-paste way.\n\nScreen:\n${screenOf(entry)}`;
    }
    const persons = run.active && !run.secret && (run.paste || run.step === "device" || run.step === "open") && !(run.waiting && !run.paste);
    if (persons) {
      await this.#card(entry);
      entry.waited = true;
      await this.#until(entry);
      if (run.active) entry.waited = false;
    }
    if (!run.active) return await this.#finished(entry);
    const state = JSON.stringify({ id: run.id, state: run.state, ...(run.waiting ? { waiting: true } : {}) });
    const next = run.secret
      ? "It asks for a secret, read without echo: do not type it. Cancel it, and use the tool's browser or device-code way, or say it cannot be done here."
      : run.waiting && !run.paste
        ? "It waits on the prompt above: answer it with id, input and key (its default, or what the task needs). If it says the page gives a code to paste back, call with id and paste: true."
        : persons
          ? "The card is still waiting for the person. End your turn with need_human: you are told when the login ends."
          : "It is still working: call again with this id.";
    return `${state}\n\nScreen:\n${screenOf(entry)}\n\n${next}`;
  }

  /// Until it ends, its prompt needs its agent, or the person has had long enough.
  async #until(entry: Entry): Promise<void> {
    const deadline = this.#fibers.now() + this.#personMs;
    while (entry.run.active && this.#fibers.now() < deadline) {
      await this.#within(entry.run.nextQuiet(), deadline - this.#fibers.now());
      if (entry.run.waiting && !entry.run.paste) return;
    }
  }

  async #within(what: Promise<void>, ms: number): Promise<void> {
    await new Promise<void>((resolve) => {
      const cancel = this.#fibers.after(Math.max(ms, 0), resolve);
      void what.then(() => {
        cancel();
        resolve();
      });
    });
  }

  async #card(entry: Entry): Promise<void> {
    const { run } = entry;
    const answer = await this.#host.call(entry.session, "oauth.login_card", {
      login: run.id,
      program: entry.program,
      reason: entry.reason,
      ...(run.codeUrl ?? run.url ? { url: run.codeUrl ?? run.url } : {}),
      ...(run.code ? { code: run.code } : {}),
      ...(run.paste ? { paste: true } : {}),
    });
    if (answer?.error) throw new Error(`The card could not be put up: ${typeof answer.content === "string" ? answer.content : answer.error}`);
    entry.card = true;
  }

  /// What it came to; its card closed and its files kept, once.
  #finished(entry: Entry): Promise<string> {
    entry.ended ??= this.#ended(entry);
    return entry.ended;
  }

  async #ended(entry: Entry): Promise<string> {
    const { run } = entry;
    const done = run.state === "done";
    if (entry.card) {
      try {
        await this.#host.call(entry.session, "oauth.login_card", { login: run.id, program: entry.program, ended: done ? "done" : "failed" });
      } catch (error) {
        log.warn("logins", "its card was not closed", { error: (error as Error).message });
      }
    }
    if (!done) return run.state === "cancelled" ? "The login was cancelled." : `The login failed: ${run.error ?? "it ended"}\n\nScreen:\n${screenOf(entry)}`;
    const kept = await this.#keep(entry);
    return `It finished (its command exited 0). Run your command again.${kept ? " The login is kept for this person, so a lost disk costs no new login." : " Its files could not be kept, so a lost disk means logging in again."}`;
  }

  /// A finished login's files, to Salix for the Task's person.
  async #keep(entry: Entry): Promise<boolean> {
    const home = platform.home(process.env);
    if (!home) return false;
    try {
      const found: string[] = [];
      changedFiles(home, entry.since, found);
      if (found.length === 0 || found.length > MAX_KEPT_FILES) return false;
      const archive = (await tar(["-czf", "-", "-C", home, ...found.map((f) => f.slice(home.length + 1))])).toString("base64");
      if (archive.length > MAX_KEPT_BYTES) return false;
      const answer = await this.#host.keep(entry.session, entry.program, archive);
      return answer?.kept === true;
    } catch (error) {
      log.warn("logins", "a login was not kept", { error: (error as Error).message });
      return false;
    }
  }

  async #restored(session: string, program: string, home: string | undefined): Promise<boolean> {
    if (!home || program === "") return false;
    const answer = await this.#host.restore(session, program).catch(() => null);
    if (typeof answer?.archive !== "string" || answer.archive === "") return false;
    const dir = mkdtempSync(join(tmpdir(), "comma-login-"));
    try {
      const file = join(dir, "login.tgz");
      writeFileSync(file, Buffer.from(answer.archive, "base64"), { mode: 0o600 });
      await tar(["-xzf", file, "-C", home]);
      return true;
    } catch (error) {
      log.warn("logins", "a kept login was not put back", { error: (error as Error).message });
      return false;
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  /// Stand-ins for the browser, first on the command's PATH: each writes the pages it is given to the file the login names.
  #shims(): string {
    const dir = join(this.#data, "run", "login-shims");
    mkdirSync(dir, { recursive: true });
    const pages = `#!/bin/sh\n# A browser for a login command the station runs (logins/run.ts): the page goes to the station.\n[ -n "$COMMA_LOGIN_OPENED" ] || exit 0\nfor a in "$@"; do printf '%s\\n' "$a" >> "$COMMA_LOGIN_OPENED"; done\nexit 0\n`;
    // Python's opener before 3.14 says `open location "…"` on osascript's stdin.
    const osascript = `#!/bin/sh\n# osascript for a login command the station runs (logins/run.ts): the page goes to the station.\n[ -n "$COMMA_LOGIN_OPENED" ] || exit 0\nprintf '%s\\n' "$*" >> "$COMMA_LOGIN_OPENED"\n[ -t 0 ] || cat >> "$COMMA_LOGIN_OPENED"\nexit 0\n`;
    for (const [name, text] of [["browser", pages], ["open", pages], ["xdg-open", pages], ["osascript", osascript]] as const) {
      const path = join(dir, name);
      let same = false;
      try {
        same = readFileSync(path, "utf8") === text;
      } catch {}
      if (!same) platform.makeCommand(path, text);
    }
    return dir;
  }

  close(): void {
    for (const entry of this.#entries.values()) entry.run.close();
    this.#entries.clear();
  }
}
