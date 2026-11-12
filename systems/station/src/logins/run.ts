// One login (docs/remote-login.md, 怎么做到): a login command run on this machine in a pseudo-terminal (the system's
// `script`, 200 × 40), with stand-ins for the browser (BROWSER, and `open`, `xdg-open`, `osascript` first on its PATH)
// that hand the page it would open to the station instead. What a person has to do is read from three places: the page
// it opens, what it prints (pages, a device code, prompts), and whether it has stopped on a prompt. Its screen is kept by
// a terminal emulator with no display (@xterm/headless), which also answers what the program asks of its terminal (the
// cursor's place, the background colour: gh waits for both). Nothing it shows is logged or kept on disk.
import { type ChildProcess } from "node:child_process";
import { type FSWatcher, readFileSync, watch } from "node:fs";
import { basename, dirname } from "node:path";
import { StringDecoder } from "node:string_decoder";
import xterm from "@xterm/headless";
import type { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { endCommand, startCommand } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import { commandsOf, descendantsOf, echoesOf, started, terminalOf } from "./terminal.ts";
import { type Loopback, asksEnter, assignmentsOf, deviceCodeIn, deviceUrls, loopbackOf, plainText, prompts, saysDone, secretAsked, storesSecret, unwrapped, urlsIn } from "./command-output.ts";

export const COLS = 200;
export const ROWS = 40;
/// How long a login may take before it is ended (a device code lasts 5 to 15 minutes; a browser left open, as long).
export const TIMEOUT_MS = 15 * 60_000;
/// Output quiet this long: the command waits (on a prompt, or for the browser).
export const QUIET_MS = 500;
/// Silent this long once it has no more need of anyone (the browser came back, it said it is logged in, or what it
/// started waits on a keychain or a credential store), not at a prompt: stuck, and ended (the overall time still holds).
export const STALL_MS = 3 * 60_000;
/// How much of what it said is kept to read (pages and codes come early).
const SAID_KEPT = 32_000;
/// An ended command's group is killed outright this long after it was asked to stop.
const KILL_MS = 3_000;

export type LoginState = "starting" | "browser" | "code" | "input" | "verifying" | "done" | "failed" | "cancelled";
export type Step = "loopback" | "device" | "open" | "terminal";
export type Key = "Enter" | "Backspace" | "Up" | "Down" | "Left" | "Right" | "Tab" | "Ctrl-C";

export const KEYS: Record<Key, string> = { Enter: "\r", Backspace: "\u007f", Up: "\u001b[A", Down: "\u001b[B", Right: "\u001b[C", Left: "\u001b[D", Tab: "\t", "Ctrl-C": "\u0003" };

export type Screen = { rows: string[]; cursor: { x: number; y: number }; echo: boolean; live: boolean };

export type RunOptions = {
  id: string;
  command: string[];
  /// The command's environment (PATH as the station's): the stand-ins are put first.
  env: Record<string, string>;
  cwd: string;
  /// Where the stand-ins are (one directory for all logins), and the file this login's write the pages to.
  shims: string;
  opened: string;
  fibers: Fibers;
  /// Its state, step, page or code changed.
  changed(): void;
  /// Its screen changed.
  drawn(): void;
};

export class LoginRun {
  readonly id: string;
  readonly command: string[];
  readonly startedAt: number;
  readonly expiresAt: number;
  state: LoginState = "starting";
  step: Step | null = null;
  url: string | null = null;
  loopback: Loopback | null = null;
  code: string | null = null;
  codeUrl: string | null = null;
  waiting = false;
  /// Its agent saw it wait for what its page gives (gcloud --no-launch-browser's "enter the verification code", Devin's
  /// "copy the code and paste it below"): the person's to enter, from their card, not its agent's. Not told from its
  /// words here (用户定: 不自动判断); kept while what they entered is checked (verifying), over once it ends.
  paste = false;
  echo = true;
  error: string | null = null;
  endedAt: number | null = null;
  /// Its callback was relayed (once only).
  relayed = false;
  /// Ended for want of time.
  timedOut = false;
  /// It has asked a person for a browser step (a page, a code) at some point.
  hadBrowserStep = false;
  /// Who are waiting for it to go quiet again (or end): its agent, after it started it or typed into it.
  #quietWaiters: (() => void)[] = [];
  readonly #o: RunOptions;
  #child: ChildProcess | null = null;
  #term: InstanceType<typeof xterm.Terminal>;
  #said = "";
  #cr = "";
  #opened: string[] = [];
  #rows: string[] = Array.from({ length: ROWS }, () => "");
  #cursor = { x: 0, y: 0 };
  #exited = false;
  #quiet: (() => void) | null = null;
  #timeout: () => void = () => {};
  #watcher: FSWatcher | null = null;
  /// The prompt last answered for the person (its line and place), so it is answered once.
  #answered = "";
  /// What it has said since its browser step was first asked for (the end kept), and whether that says it is logged in.
  #afterStep = "";
  #saidDone = false;
  #stall: () => void = () => {};

  constructor(o: RunOptions) {
    this.#o = o;
    this.id = o.id;
    this.command = o.command;
    this.startedAt = o.fibers.now();
    this.expiresAt = this.startedAt + TIMEOUT_MS;
    this.#term = new xterm.Terminal({ cols: COLS, rows: ROWS, scrollback: 200, allowProposedApi: true });
    // What the program asks of its terminal, answered as a terminal would: the cursor's place and the like by the
    // emulator itself, the colours here (a light terminal).
    this.#term.onData((reply) => this.#write(reply));
    this.#term.parser.registerOscHandler(10, (data) => (data === "?" ? (this.#write("\u001b]10;rgb:0000/0000/0000\u001b\\"), true) : false));
    this.#term.parser.registerOscHandler(11, (data) => (data === "?" ? (this.#write("\u001b]11;rgb:ffff/ffff/ffff\u001b\\"), true) : false));
  }

  get active(): boolean {
    return this.endedAt === null;
  }

  /// The processes it runs as: `script` (or the command itself) and all it started.
  async pids(): Promise<number[]> {
    const pid = this.#child?.pid;
    if (pid === undefined || this.#exited) return [];
    return [pid, ...(await descendantsOf(pid))];
  }

  screen(): Screen {
    return { rows: [...this.#rows], cursor: { ...this.#cursor }, echo: this.echo, live: this.active };
  }

  /// Starts the command; one that cannot be run ends failed, saying why.
  async start(): Promise<void> {
    // `NAME=value claude auth login`: the environment it is given, as a shell takes it, not a program to run.
    const given = assignmentsOf(this.command, platform.home(this.#o.env));
    const [program, ...args] = given.rest;
    if (program === undefined) return this.#fail("That is not a command.");
    let env: Record<string, string> = { ...(platform.prependPath(this.#o.env, this.#o.shims) as Record<string, string>) };
    const browser = `${this.#o.shims}/${platform.exe("browser")}`;
    // What it is given, but not the stand-ins for the browser: the page it opens is the person's to open.
    Object.assign(env, given.env, {
      TERM: "xterm-256color",
      COLUMNS: String(COLS),
      LINES: String(ROWS),
      BROWSER: browser,
      GH_BROWSER: browser,
      COMMA_LOGIN_OPENED: this.#o.opened,
    });
    keychainOutOfGit(env);
    const wrapped = terminalOf(program!, args, COLS, ROWS) ?? [program!, args];
    const r = platform.runnable(wrapped[0], wrapped[1], env);
    let child: ChildProcess;
    try {
      child = startCommand(r.file, r.args, { cwd: this.#o.cwd, env, stdio: ["pipe", "pipe", "pipe"] });
    } catch (e) {
      return this.#fail(`It could not be run: ${(e as Error).message}`);
    }
    this.#child = child;
    const spawned = await started(child);
    if (spawned) {
      this.#exited = true;
      return this.#fail(`It could not be run: ${spawned.message}`);
    }
    child.stdin?.on("error", () => {});
    const decoders = [new StringDecoder("utf8"), new StringDecoder("utf8")];
    [child.stdout, child.stderr].forEach((stream, i) => stream?.on("data", (chunk: Buffer) => this.#output(decoders[i]!.write(chunk))));
    child.once("close", (code, signal) => void this.#closed(code, signal));
    this.#timeout = this.#o.fibers.after(TIMEOUT_MS, () => this.#fail("It ran out of time.", "timeout"));
    this.#watchStall();
    // The pages it opens, as its stand-ins write them.
    try {
      const file = basename(this.#o.opened);
      this.#watcher = watch(dirname(this.#o.opened), { persistent: false }, (_event, name) => {
        if (name === null || name === file) this.#read();
      });
      this.#watcher.on("error", () => {});
    } catch {}
    log.info("logins", "a login started", { id: this.id, command: this.command[0] });
    this.#o.changed();
  }

  /// Whether it waits on a line typed without echo: a secret (a password), which nobody types for it here.
  get secret(): boolean {
    return this.active && this.waiting && !this.echo;
  }

  /// Resolves the next time its output has gone quiet and been looked at (what it waits on is known then), or it ends.
  nextQuiet(): Promise<void> {
    if (!this.active) return Promise.resolve();
    return new Promise((resolve) => this.#quietWaiters.push(resolve));
  }

  #quietNow(): void {
    for (const wake of this.#quietWaiters.splice(0)) wake();
  }

  /// Typed into its terminal: text as it is, or a key.
  input(given: { text?: string; key?: Key }): void {
    if (!this.active) return;
    if (given.key !== undefined) this.#write(KEYS[given.key]);
    else if (given.text !== undefined) this.#write(given.text);
  }

  /// Cancelled by a person (or the station going): its command ended.
  cancel(): void {
    if (!this.active) return;
    this.#end("cancelled", null);
  }

  #write(text: string): void {
    const stdin = this.#child?.stdin;
    if (!stdin || stdin.destroyed || this.#exited) return;
    stdin.write(text);
  }

  #output(text: string): void {
    if (text === "" || !this.active) return;
    // A line's "\r" at a chunk's end is read with what follows it ("\r\n" split in two is one line's end).
    const whole = this.#cr + text;
    this.#cr = /\r+$/.exec(whole)?.[0] ?? "";
    const plain = plainText(whole.slice(0, whole.length - this.#cr.length));
    const said = this.#said + plain;
    this.#said = said.length > SAID_KEPT ? said.slice(said.length - SAID_KEPT) : said;
    if (this.hadBrowserStep && !this.#saidDone) {
      this.#afterStep = (this.#afterStep + plain).slice(-4_000);
      this.#saidDone = saysDone(this.#afterStep);
    }
    this.#watchStall();
    this.#term.write(text, () => {
      this.#draw();
      // Saying more, it no longer waits on what it asked (whether it waits now is asked once it is quiet again).
      if (this.waiting) {
        this.waiting = false;
        this.#o.changed();
      }
      this.#read();
    });
    // Quiet again from now: whether it waits is asked once it has said its piece.
    this.#quiet?.();
    this.#quiet = this.#o.fibers.after(QUIET_MS, () => void this.#settled());
  }

  /// The screen as the emulator has it now; told when it changed.
  #draw(): void {
    const buffer = this.#term.buffer.active;
    const rows = Array.from({ length: ROWS }, (_, i) => buffer.getLine(buffer.baseY + i)?.translateToString(true) ?? "");
    const cursor = { x: buffer.cursorX, y: buffer.cursorY };
    const same = rows.every((r, i) => r === this.#rows[i]) && cursor.x === this.#cursor.x && cursor.y === this.#cursor.y;
    this.#rows = rows;
    this.#cursor = cursor;
    if (!same) this.#o.drawn();
  }

  /// What it asks of a person now, from the pages it opened and what it said.
  #read(): void {
    if (!this.active) return;
    try {
      const text = readFileSync(this.#o.opened, "utf8");
      this.#opened = urlsIn(text);
    } catch {}
    const before = JSON.stringify([this.state, this.step, this.url, this.loopback, this.code, this.codeUrl, this.waiting]);
    // As it said them, a link broken at the terminal's width put together again.
    const said = unwrapped(this.#said, COLS);
    const printed = urlsIn(said);
    // The page it opens, over what it prints: they may differ (Claude Code prints its paste-a-code page and opens its
    // loopback one; codex prints localhost and comes back to 127.0.0.1).
    const page = this.#opened.at(-1) ?? null;
    const back = page !== null ? loopbackOf(page) : null;
    const printedBack = page === null ? printed.find((u) => loopbackOf(u) !== null) ?? null : null;
    const code = deviceCodeIn(said);
    if (this.state === "verifying") {
      // The browser came back: nothing more to do but wait for it to finish.
    } else if (back !== null || printedBack !== null) {
      this.url = page !== null && back !== null ? page : printedBack;
      this.loopback = back ?? loopbackOf(printedBack!);
      this.step = "loopback";
      this.state = "browser";
      this.code = null;
    } else if (code !== null) {
      const urls = deviceUrls([...this.#opened, ...printed], code);
      this.code = code;
      this.url = urls.url;
      this.codeUrl = urls.codeUrl;
      this.step = "device";
      this.state = "code";
    } else if (page !== null || printed.some((u) => u.startsWith("https://"))) {
      this.url = page ?? printed.filter((u) => u.startsWith("https://")).at(-1)!;
      this.step = "open";
      this.state = "browser";
    }
    if (this.step === "device" || this.step === "loopback" || this.step === "open") this.hadBrowserStep = true;
    if (JSON.stringify([this.state, this.step, this.url, this.loopback, this.code, this.codeUrl, this.waiting]) !== before) this.#o.changed();
  }

  /// Its output has been quiet a while: Enter pressed where it only asks for Enter to open its page in a browser (gh,
  /// npm, docker: nothing to choose, and the stand-in takes the page); any other prompt, a question (Y/n) included, is
  /// the person's to answer in the terminal: it waits for them.
  async #settled(): Promise<void> {
    this.#quiet = null;
    if (!this.active || this.#exited) return;
    const line = this.#rows[this.#cursor.y] ?? "";
    // Its "Press Enter to open … in your browser": on the cursor's line, or (gh) the line above it, the cursor on an empty
    // one under it. Pressed by the station whenever it asks (nothing opens on this machine: the stand-ins take the page).
    const asked = line.trim() !== "" ? this.#cursor.y : this.#lastSaidAbove(this.#cursor.y);
    const askLine = asked !== null ? this.#rows[asked] ?? "" : "";
    const place = `${asked}\0${askLine}`;
    if (place !== this.#answered && asksEnter(askLine)) {
      this.#answered = place;
      this.#write("\r");
      // Its page comes now: what it waits on is known once it is quiet again.
      return;
    }
    const waiting = line.trim() !== "" && prompts(line) && this.state !== "verifying";
    let echo = this.echo;
    if (waiting) {
      // Asked of the first of its processes that is on the terminal (not `script` itself, nor what feeds it).
      let told: boolean | null = null;
      for (const pid of (await this.pids()).slice(1)) {
        told = await echoesOf(pid);
        if (told !== null) break;
      }
      echo = told ?? !secretAsked(line);
      if (!this.active) return;
    }
    const changed = waiting !== this.waiting || (waiting && this.step === null);
    this.waiting = waiting;
    if (waiting && this.step === null) {
      this.step = "terminal";
      this.state = "input";
    }
    if (echo !== this.echo) {
      this.echo = echo;
      this.#o.drawn();
    }
    if (changed) this.#o.changed();
    this.#quietNow();
  }

  /// The nearest line above `y` with something on it (within a few lines: what it asks is just above), if any.
  #lastSaidAbove(y: number): number | null {
    for (let i = y - 1; i >= Math.max(0, y - 3); i--) if ((this.#rows[i] ?? "").trim() !== "") return i;
    return null;
  }

  /// Watches for it going silent once nothing is left for anyone to do (STALL_MS): restarted by every output.
  #watchStall(): void {
    this.#stall();
    if (!this.active) return;
    this.#stall = this.#o.fibers.after(STALL_MS, () => void this.#stalled());
  }

  async #stalled(): Promise<void> {
    if (!this.active || this.#exited) return;
    const stuck = !this.waiting && (this.relayed || this.#saidDone || (await commandsOf((await this.pids()).slice(1))).some(storesSecret));
    if (!this.active) return;
    if (!stuck) return this.#watchStall();
    const screen = this.#rows.map((r) => r.trimEnd()).filter((r) => r.trim() !== "").slice(-8).join("\n");
    log.info("logins", "a login stalled", { id: this.id });
    this.#fail(`${`It stopped responding for ${STALL_MS / 60_000} minutes.`}${screen !== "" ? `\n${screen}` : ""}`, "timeout");
  }

  /// Whether the person enters what its page gives on their card (its agent says so): only once it has given a page to
  /// open, and never at a prompt that reads a secret.
  askPaste(on: boolean): boolean {
    if (!this.active || (on && (this.step !== "open" || this.url === null || this.secret))) return false;
    // Asked again (what was entered was refused): it waits on the person once more, no longer finishing.
    const again = on && this.state === "verifying";
    if (again) this.state = "browser";
    if (on !== this.paste || again) {
      this.paste = on;
      this.#o.changed();
    }
    return true;
  }

  /// The person entered what its page gave, and Enter: it finishes by itself now (or asks again, its agent says so). Its
  /// card keeps the field, what was entered checked in place.
  answeredNow(): void {
    if (!this.active) return;
    this.state = "verifying";
    this.waiting = false;
    this.#o.changed();
  }

  /// Its browser came back and the callback went to it: it finishes by itself now.
  relayedNow(): void {
    this.relayed = true;
    if (this.active && this.state !== "verifying") {
      this.state = "verifying";
      this.waiting = false;
      this.paste = false;
      this.#o.changed();
    }
  }

  async #closed(code: number | null, signal: NodeJS.Signals | null): Promise<void> {
    this.#exited = true;
    if (!this.active) return;
    if (code === 0) return this.#end("done", null);
    const said = lastLines(this.#said);
    this.#end("failed", said !== "" ? said : `It exited with ${code !== null ? String(code) : (signal ?? "signal")}.`);
  }

  #fail(error: string, why?: "timeout"): void {
    if (!this.active) return;
    if (why === "timeout") this.timedOut = true;
    this.#end("failed", error);
  }

  #end(state: LoginState, error: string | null): void {
    if (!this.active) return;
    this.state = state;
    this.error = error;
    this.waiting = false;
    this.paste = false;
    this.endedAt = this.#o.fibers.now();
    this.#timeout();
    this.#stall();
    this.#quiet?.();
    this.#quiet = null;
    this.#watcher?.close();
    this.#watcher = null;
    const child = this.#child;
    if (child && !this.#exited) {
      child.stdin?.end();
      endCommand(child, "SIGTERM");
      this.#o.fibers.after(KILL_MS, () => {
        if (!this.#exited) endCommand(child, "SIGKILL");
      });
    }
    log.info("logins", "a login ended", { id: this.id, state });
    this.#o.changed();
    this.#o.drawn();
    this.#quietNow();
  }

  /// Stops listening to it for good (the station closing): its command ended.
  close(): void {
    this.cancel();
    this.#term.dispose();
  }
}

/// Git's credential helpers left out for a login's command and what it starts: a station's command has nobody to answer
/// the macOS keychain's dialog, so `git credential-osxkeychain` (Homebrew's or Apple's git sets it system-wide) waits on
/// it forever (gh, told to authenticate git, stores its token through git's helper). An empty `credential.helper` given
/// on git's command line (GIT_CONFIG_COUNT, read after every file) clears the helpers the files name, for this process
/// only: no file is written, the person's ~/.gitconfig as it was. gh, finding no helper, sets up its own
/// (`!gh auth git-credential`, in ~/.gitconfig, as `gh auth setup-git` does).
export function keychainOutOfGit(env: Record<string, string>): void {
  const n = Number.parseInt(env.GIT_CONFIG_COUNT ?? "", 10);
  const at = Number.isInteger(n) && n >= 0 ? n : 0;
  env[`GIT_CONFIG_KEY_${at}`] = "credential.helper";
  env[`GIT_CONFIG_VALUE_${at}`] = "";
  env.GIT_CONFIG_COUNT = String(at + 1);
}

/// The last few lines of what a command said, for why it failed.
export function lastLines(said: string): string {
  const lines = said
    .trim()
    .split("\n")
    .map((l) => l.trimEnd())
    .filter((l) => l.trim() !== "");
  return [...lines.slice(Math.max(0, lines.length - 6)).join("\n")].slice(0, 800).join("");
}
