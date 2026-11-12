// What a person debugging an app on an iOS Simulator has beside its picture: its restart, a picture and a movie of the
// device, an app put on it and light or dark, all simctl's. Ported from still.fail's station/src/screens/sim-debug.ts
// (afk/main): its `appsOf`, `relaunch`, `settings`/`setSetting`, `install`/`appIn`, `recordStart`/`recordStop`, `turnOf`,
// `turnMovie`, `screenshot` and `recorder`. Its logs are screens/app-logs.ts here.
//
// Deviations:
// - `restart` takes no app: the newest of the apps a person installed that run now, the app the logs pane shows.
//   still.fail's viewer names one from its App tab, which Comma has none of.
// - A recording's folder is the device's own: still.fail's one folder is emptied as any device starts, which takes the
//   movie from under another device recording.
// - Not ported, not asked for here: text size, opening a URL, location, the status bar, biometrics, uninstall, push.
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import { mkdtemp, open, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { RecordingFiles, type RecordedMovie } from "./recording-files.ts";
import { wall } from "../ops/fibers.ts";
import type { DeviceAppearance, DeviceDebug, DeviceDebugAction, DevicePanelName } from "./source.ts";

/// An app a person installed on the device.
export type SimApp = { id: string; name: string; running: boolean };
export type Run = (file: string, args: string[]) => Promise<string>;
/// `simctl io recordVideo`'s process.
export type Recorder = (args: string[]) => { started: Promise<void>; ended: Promise<void>; stop: () => void };

const ACTIONS: readonly DeviceDebugAction[] = ["restart", "screenshot", "record", "install", "appearance"];
const INSTALL_TYPES = [".ipa", ".zip"] as const;
const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9.-]*$/;
const APP_DEPTH = 3;
/// The panels of an iPhone Duo as `simctl io` numbers its displays.
const DISPLAY_COVER = 1;
const DISPLAY_INNER = 3;
/// The longest a recording goes on: one left running does not fill the disk (some 80 MB a minute).
const RECORD_MS = 10 * 60_000;
const RECORD_START_MS = 5_000;
const RECORD_STOP_MS = 15_000;

/// The quarter turns clockwise a panel's picture is shown at, from `simctl io enumerate`'s words of it.
export function turnOf(said: string, panel: string): number {
  for (const block of said.split("Device Name: ").slice(1)) {
    if (!block.startsWith(`${panel}\n`)) continue;
    const line = block.split("\n").find((l) => l.includes("UI Orientation:"));
    if (line?.trimEnd().endsWith("Landscape Left")) return 1;
    if (line?.trimEnd().endsWith("Landscape Right")) return 3;
    if (line?.trimEnd().endsWith("Portrait Upside Down")) return 2;
    return 0;
  }
  return 0;
}

/// The movie at `file` said to be shown `turn` quarter turns clockwise (its video track's matrix): nothing encoded again.
export async function turnMovie(file: string, turn: number): Promise<boolean> {
  const f = await open(file, "r+");
  try {
    const { size } = await f.stat();
    if (size === 0) return false;
    if (turn === 0) return true;
    const head = async (at: number): Promise<[string, number, number]> => {
      const b = Buffer.alloc(16);
      await f.read(b, 0, 16, at);
      const short = b.readUInt32BE(0);
      const long = short === 1;
      return [b.toString("latin1", 4, 8), long ? Number(b.readBigUInt64BE(8)) : short === 0 ? size - at : short, long ? 16 : 8];
    };
    const find = async (name: string, from: number, to: number): Promise<[number, number, number] | null> => {
      for (let at = from; at + 8 <= to; ) {
        const [kind, length, skip] = await head(at);
        if (length < 8) return null;
        if (kind === name) return [at + skip, at + length, length];
        at += length;
      }
      return null;
    };
    const moov = await find("moov", 0, size);
    if (moov === null) return false;
    for (let at = moov[0]; at + 8 <= moov[1]; ) {
      const [kind, length, skip] = await head(at);
      if (length < 8) return false;
      if (kind === "trak") {
        const tkhd = await find("tkhd", at + skip, at + length);
        const mdia = await find("mdia", at + skip, at + length);
        const hdlr = mdia && (await find("hdlr", mdia[0], mdia[1]));
        const handler = Buffer.alloc(4);
        if (hdlr) await f.read(handler, 0, 4, hdlr[0] + 8);
        if (tkhd && handler.toString("latin1") === "vide") {
          const version = Buffer.alloc(1);
          await f.read(version, 0, 1, tkhd[0]);
          const matrix = tkhd[0] + (version[0] === 1 ? 52 : 40);
          const shape = Buffer.alloc(8);
          await f.read(shape, 0, 8, matrix + 36);
          const [w, h] = [shape.readUInt32BE(0), shape.readUInt32BE(4)];
          const one = 0x10000;
          // a b u, c d v, tx ty w: (x, y) goes to (ax + cy + tx, bx + dy + ty), in 16.16 but u, v and w
          const m = turn === 1 ? [0, one, 0, -one, 0, 0, h, 0] : turn === 2 ? [-one, 0, 0, 0, -one, 0, w, h] : [0, -one, 0, one, 0, 0, 0, w];
          const out = Buffer.alloc(36);
          m.forEach((v, i) => out.writeInt32BE(v, i * 4));
          out.writeInt32BE(0x40000000, 32);
          await f.write(out, 0, 36, matrix);
          return true;
        }
      }
      at += length;
    }
    return false;
  } finally {
    await f.close();
  }
}

/// The first .app under `dir`, at most `depth` folders down (an .ipa's in Payload, a build's zip with a folder round it).
async function appIn(dir: string, depth: number): Promise<string | null> {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const e of entries) if (e.isDirectory() && e.name.endsWith(".app")) return join(dir, e.name);
  if (depth <= 0) return null;
  for (const e of entries) {
    if (!e.isDirectory() || e.name === "__MACOSX") continue;
    const found = await appIn(join(dir, e.name), depth - 1);
    if (found !== null) return found;
  }
  return null;
}

/// The apps a person installed, from `simctl listapps` (as JSON) and what `launchctl list` inside the device runs.
export function appsOf(installed: unknown, launchctl: string): SimApp[] {
  const running = new Set([...launchctl.matchAll(/UIKitApplication:([^\[\s]+)\[/g)].map((m) => m[1]!));
  const apps: SimApp[] = [];
  for (const [id, app] of Object.entries((installed ?? {}) as Record<string, any>)) {
    if (app?.ApplicationType !== "User") continue;
    const name = [app.CFBundleDisplayName, app.CFBundleName].find((n) => typeof n === "string" && n !== "");
    apps.push({ id, name: name ?? id, running: running.has(id) });
  }
  return apps.sort((a, b) => Number(b.running) - Number(a.running) || a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
}

/// Of `apps`, the one started last by `launchctl list` (its first column, the pid, the newest the highest); null: none runs.
export function newestRunning(apps: readonly SimApp[], launchctl: string): SimApp | null {
  let newest: SimApp | null = null;
  let pid = -1;
  for (const m of launchctl.matchAll(/^(\d+)\s+\S+\s+UIKitApplication:([^\[\s]+)\[/gm)) {
    const app = apps.find((a) => a.id === m[2]);
    if (app && Number(m[1]) > pid) [newest, pid] = [app, Number(m[1])];
  }
  return newest;
}

const recorder: Recorder = (args) => {
  const child: ChildProcess = spawn(args[0]!, args.slice(1), { stdio: ["ignore", "pipe", "ignore"] });
  const ended = new Promise<void>((done) => {
    child.on("error", () => done());
    child.on("close", () => done());
  });
  const started = new Promise<void>((done) => {
    child.stdout!.setEncoding("utf8");
    child.stdout!.on("data", (chunk: string) => {
      if (chunk.includes("Recording started")) done();
    });
    void ended.then(done);
    wall.after(RECORD_START_MS, done);
  });
  return {
    started,
    ended,
    stop: () => {
      // (SIGINT is what ends it with its movie whole)
      child.kill("SIGINT");
      wall.after(RECORD_STOP_MS, () => void child.kill("SIGKILL"));
    },
  };
};

/// One booted device's debugging.
export class SimDebug implements DeviceDebug {
  readonly actions = ACTIONS;
  readonly installTypes = INSTALL_TYPES;
  readonly #simctl: string;
  readonly #udid: string;
  readonly #run: Run;
  readonly #picture: () => Promise<Uint8Array>;
  readonly #record: Recorder;
  readonly #files = new RecordingFiles();
  #closed = false;
  #serial: Promise<unknown> = Promise.resolve();
  #recording: { child: ReturnType<Recorder>; folder: string; name: string; turn: number; limit: () => void } | null = null;

  /// `picture`: the device's screen as a view has it (a JPEG): not `simctl io`'s, which of a foldable's screens it picks
  /// is not the one in use (an iPhone Duo's: black).
  constructor(simctl: string, udid: string, run: Run, picture: () => Promise<Uint8Array>, record: Recorder = recorder) {
    this.#simctl = simctl;
    this.#udid = udid;
    this.#run = run;
    this.#picture = picture;
    this.#record = record;
  }

  async #listed(): Promise<[SimApp[], string]> {
    const [installed, launchctl] = await Promise.all([
      // listapps says an old-style plist, which only plutil reads, from its stdin here.
      this.#run("/bin/sh", ["-c", '"$0" listapps "$1" | plutil -convert json -o - -', this.#simctl, this.#udid]),
      this.#run(this.#simctl, ["spawn", this.#udid, "launchctl", "list"]),
    ]);
    return [appsOf(JSON.parse(installed), launchctl), launchctl];
  }

  /// Ends the app a person installed that runs now and starts it again; null when none runs.
  async restart(): Promise<{ app: string; name: string } | null> {
    const newest = newestRunning(...(await this.#listed()));
    if (newest === null || !BUNDLE_ID.test(newest.id)) return null;
    await this.#run(this.#simctl, ["launch", "--terminate-running-process", this.#udid, newest.id]);
    return { app: newest.id, name: newest.name };
  }

  async state(): Promise<{ recording: boolean; appearance?: DeviceAppearance }> {
    const appearance = (await this.#run(this.#simctl, ["ui", this.#udid, "appearance"])).trim();
    return { recording: this.#recording !== null, ...(appearance === "light" || appearance === "dark" ? { appearance } : {}) };
  }

  async setAppearance(value: DeviceAppearance): Promise<void> {
    await this.#run(this.#simctl, ["ui", this.#udid, "appearance", value]);
  }

  /// Where a file to install goes up to.
  installFolder(): string {
    const folder = join(tmpdir(), "comma-sim-install");
    mkdirSync(folder, { recursive: true });
    return folder;
  }

  /// The app in `path` (an .ipa, or a .zip with a .app in it, in `installFolder`) installed and started, the file let go of:
  /// its bundle id; null when that is no such file or there is no app in it.
  async install(path: string): Promise<{ app: string } | null> {
    if (dirname(resolve(path)) !== this.installFolder() || !/\.(ipa|zip)$/i.test(path) || basename(path).startsWith("-")) return null;
    const out = await mkdtemp(join(tmpdir(), "comma-sim-app-"));
    try {
      // (what does not unpack is no such file either)
      if (!(await this.#run("ditto", ["-x", "-k", path, out]).then(() => true, () => false))) return null;
      const app = await appIn(out, APP_DEPTH);
      if (app === null) return null;
      await this.#run(this.#simctl, ["install", this.#udid, app]);
      const id = JSON.parse(await this.#run("plutil", ["-convert", "json", "-o", "-", join(app, "Info.plist")])).CFBundleIdentifier;
      if (typeof id !== "string" || !BUNDLE_ID.test(id)) return null;
      await this.#run(this.#simctl, ["launch", "--terminate-running-process", this.#udid, id]);
      return { app: id };
    } finally {
      await Promise.all([rm(out, { recursive: true, force: true }), rm(path, { force: true })]);
    }
  }

  #enqueue<T>(run: () => Promise<T>): Promise<T> {
    const next = this.#serial.then(run);
    this.#serial = next.catch(() => {});
    return next;
  }

  /// Starts recording its screen, `panel`'s where it has two. An existing recording continues.
  recordStart(panel: DevicePanelName | null): Promise<void> {
    return this.#enqueue(() => this.#start(panel));
  }

  async #start(panel: DevicePanelName | null): Promise<void> {
    if (this.#closed) throw new Error("the device has closed");
    if (this.#recording !== null) return;
    const folder = await this.#files.next();
    const name = `${randomBytes(4).toString("hex")}.mp4`;
    const file = join(folder, name);
    const turn = panel === "inner" ? turnOf(await this.#run(this.#simctl, ["io", this.#udid, "enumerate"]), "primary-1") : 0;
    if (this.#closed) return;
    const display = panel === null ? [] : [`--display=${panel === "inner" ? DISPLAY_INNER : DISPLAY_COVER}`];
    const child = this.#record([this.#simctl, "io", this.#udid, "recordVideo", "--codec=h264", ...display, "--force", file]);
    const limit = wall.after(RECORD_MS, () => child.stop());
    this.#recording = { child, folder, name, turn, limit };
    await child.started;
  }

  /// Ends the recording and says where its movie is; null when none goes on.
  recordStop(): Promise<RecordedMovie | null> {
    return this.#enqueue(async () => {
      const movie = await this.#stop();
      return movie === null || this.#closed ? null : this.#files.hold(movie.path);
    });
  }

  async #stop(): Promise<{ path: string } | null> {
    const r = this.#recording;
    if (r === null) return null;
    this.#recording = null;
    r.limit();
    r.child.stop();
    await r.child.ended;
    const path = join(r.folder, r.name);
    if (!(await turnMovie(path, r.turn).catch(() => false))) throw new Error("nothing was recorded");
    return { path };
  }

  /// The device's screen as a PNG, in its own pixels.
  async screenshot(): Promise<Buffer> {
    const base = join(tmpdir(), `comma-sim-${randomBytes(8).toString("hex")}`);
    try {
      await writeFile(`${base}.jpg`, await this.#picture());
      await this.#run("sips", ["-s", "format", "png", `${base}.jpg`, "--out", `${base}.png`]);
      return await readFile(`${base}.png`);
    } finally {
      await Promise.all([rm(`${base}.jpg`, { force: true }), rm(`${base}.png`, { force: true })]);
    }
  }

  /// The device shut down (or the station stops).
  close(): Promise<void> {
    this.#closed = true;
    // Stop a child now, even if its startup acknowledgment has not arrived.
    this.#recording?.limit();
    this.#recording?.child.stop();
    return this.#enqueue(async () => {
      await this.#stop().catch(() => null);
      await this.#files.close();
    });
  }
}
