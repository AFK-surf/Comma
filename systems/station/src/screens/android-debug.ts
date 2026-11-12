// What a person debugging an app on an Android emulator has beside its picture, as screens/sim-debug.ts has for an iOS
// Simulator (still.fail has no such thing for Android: this is adb's own way of each), every call pinned to the device's
// serial (`Adb`). A phone has none of this: what is on it is a person's own.
import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import type { ChildProcess } from "node:child_process";
import { RecordingFiles, type RecordedMovie } from "./recording-files.ts";
import { wall } from "../ops/fibers.ts";
import { foregroundOf, foregroundScript } from "./app-logs.ts";
import type { Adb } from "./android.ts";
import type { DeviceAppearance, DeviceDebug, DeviceDebugAction } from "./source.ts";

/// `screenrecord`'s own longest: it ends by itself then, its movie whole.
const RECORD_SECONDS = 180;
const STOP_MS = 15_000;
/// The Android whose `cmd uimode night` changes what apps are shown as (10: dark theme).
const NIGHT_SDK = 29;
const PACKAGE = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

/// What an emulator of this Android can do. `sdk`: its API level; 0 not known.
export function androidDebugActions(sdk: number): DeviceDebugAction[] {
  return ["restart", "screenshot", "record", "install", ...(sdk >= NIGHT_SDK ? (["appearance"] as const) : [])];
}

export class AndroidDebug implements DeviceDebug {
  readonly actions: readonly DeviceDebugAction[];
  readonly installTypes = [".apk"] as const;
  readonly #adb: Pick<Adb, "run" | "bytes" | "long" | "shell">;
  readonly #name: string;
  #recording: { child: ChildProcess; remote: string; ended: Promise<void> } | null = null;
  readonly #files = new RecordingFiles();
  #closed = false;
  #serial: Promise<unknown> = Promise.resolve();

  #enqueue<T>(run: () => Promise<T>): Promise<T> {
    const next = this.#serial.then(run);
    this.#serial = next.catch(() => {});
    return next;
  }

  constructor(adb: Pick<Adb, "run" | "bytes" | "long" | "shell">, sdk: number, name: string = randomBytes(4).toString("hex")) {
    this.#adb = adb;
    this.actions = androidDebugActions(sdk);
    this.#name = name;
  }

  /// Ends the app a person installed that shows now and starts it again; null when what shows is none (the launcher).
  async restart(): Promise<{ app: string; name: string } | null> {
    const { app } = foregroundOf(await this.#adb.run(["shell", foregroundScript(null)]));
    if (app === null || !PACKAGE.test(app)) return null;
    const installed = await this.#adb.run(["shell", "pm list packages -3"]);
    if (!installed.split("\n").some((l) => l.trim() === `package:${app}`)) return null;
    await this.#adb.run(["shell", `am force-stop ${app}; monkey -p ${app} -c android.intent.category.LAUNCHER 1`]);
    return { app, name: app };
  }

  async state(): Promise<{ recording: boolean; appearance?: DeviceAppearance }> {
    if (!this.actions.includes("appearance")) return { recording: this.#recording !== null };
    const said = await this.#adb.run(["shell", "cmd uimode night"]).catch(() => "");
    const night = /Night mode: (yes|no)/.exec(said)?.[1];
    return { recording: this.#recording !== null, ...(night ? { appearance: night === "yes" ? ("dark" as const) : ("light" as const) } : {}) };
  }

  async setAppearance(value: DeviceAppearance): Promise<void> {
    await this.#adb.run(["shell", `cmd uimode night ${value === "dark" ? "yes" : "no"}`]);
  }

  installFolder(): string {
    const folder = join(tmpdir(), "comma-android-install");
    mkdirSync(folder, { recursive: true });
    return folder;
  }

  /// The .apk at `path` (in `installFolder`) installed, over what is there, the file let go of. It is not started: adb does
  /// not say its package. Null: no such file.
  async install(path: string): Promise<{ app?: string } | null> {
    if (dirname(resolve(path)) !== this.installFolder() || !/\.apk$/i.test(path) || basename(path).startsWith("-")) return null;
    try {
      await this.#adb.long(["install", "-r", "-t", path]);
      return {};
    } finally {
      await rm(path, { force: true });
    }
  }

  recordStart(): Promise<void> {
    return this.#enqueue(async () => {
      if (this.#closed) throw new Error("the device has closed");
      if (this.#recording !== null) return;
      const remote = `/data/local/tmp/comma-${this.#name}-${randomBytes(4).toString("hex")}.mp4`;
      const child = this.#adb.shell(`screenrecord --time-limit ${RECORD_SECONDS} ${remote} & p=$!; echo "$p" > ${remote}.pid; wait "$p"`);
      const ended = new Promise<void>((done) => {
        child.on("error", () => done());
        child.on("close", () => done());
    });
    // (its own end, at its longest, leaves the movie to be fetched: `recordStop` still finds it)
    this.#recording = { child, remote, ended };
    });
  }

  /// Ends the recording and fetches its movie; null when none goes on.
  recordStop(): Promise<RecordedMovie | null> {
    return this.#enqueue(async () => {
      const r = this.#recording;
      if (r === null) return null;
      // Keep the slot until finalization and pull finish.
      try {
        await this.#stop(r);
        if (this.#closed) return null;
        const folder = await this.#files.next();
        const path = join(folder, "recording.mp4");
        await this.#adb.long(["pull", r.remote, path]);
        return this.#closed ? null : this.#files.hold(path);
      } finally {
        await this.#adb.run(["shell", `rm -f ${r.remote} ${r.remote}.pid`]).catch(() => "");
        this.#recording = null;
      }
    });
  }

  async #stop(r: { child: ChildProcess; remote: string; ended: Promise<void> }): Promise<void> {
    // Check the command's unique output path before signaling its PID. Leave other recorders alone.
    await this.#adb.run(["shell", `for i in $(seq 1 50); do p=$(cat ${r.remote}.pid 2>/dev/null); case "$p" in ''|*[!0-9]*) sleep 0.1; continue;; esac; [ -d /proc/$p ] || exit 0; if tr '\\0' ' ' < /proc/$p/cmdline | grep -Fq 'screenrecord --time-limit ${RECORD_SECONDS} ${r.remote} '; then kill -INT "$p"; exit; fi; sleep 0.1; done`]).catch(() => "");
    const stop = wall.after(STOP_MS, () => void r.child.kill("SIGKILL"));
    await r.ended;
    stop();
  }

  screenshot(): Promise<Buffer> {
    return this.#adb.bytes(["exec-out", "screencap", "-p"]);
  }

  /// It left adb, or the station stops. Stop only this source's recorder, then remove its movies.
  close(): Promise<void> {
    this.#closed = true;
    return this.#enqueue(async () => {
      const r = this.#recording;
      if (r !== null) {
        await this.#stop(r);
        await this.#adb.run(["shell", `rm -f ${r.remote} ${r.remote}.pid`]).catch(() => "");
        this.#recording = null;
      }
      await this.#files.close();
    });
  }
}
