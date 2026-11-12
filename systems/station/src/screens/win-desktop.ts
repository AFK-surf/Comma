// This Windows machine's main display as a screen source (`display`, docs/desktop-screen.md): comma-desktop-screen
// (native/desktop-screen) captures it with Windows.Graphics.Capture, encodes H.265 or H.264 with Media Foundation (the
// hardware encoder where there is one) and posts the input with SendInput. Each view is a process of its own, started
// with `view` and spoken to on its standard input and output in still.fail Helper's messages (screen-pipe.ts
// `HelperView`); it ends as its input does.
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 7470ca2abe) station/src/screens/win-desktop.ts:
// `screenBinary`, `WindowsDesktop` (its status, views and restarts, its clipboard and system output), `LastingView` and
// `childPipe`. Not ported, as Cue's ScreenSource has none of them: the display's scale and resolution set from a view,
// parts of the display, reveal and agent-desktop's accessibility trees (docs/desktop-screen.md, "Deviations").
//
// Nothing is granted on Windows: a station runs in its person's session (a scheduled task at logon), where the display
// can be captured and driven. What cannot be is what Windows keeps from any app there: the sign-in and UAC's secure
// desktop, and windows of apps run as administrator (their input).
import { type ChildProcess, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { hostname } from "node:os";
import { fileURLToPath } from "node:url";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { log } from "../ops/log.ts";
import { ScreenRefused } from "./hub.ts";
import { type HelperPipe, HelperView } from "./screen-pipe.ts";
import { type AudioFrame, type Clip, type ClipType, type Codec, type Frame, type ScreenCursor, type ScreenInput, type ScreenSource, type ScreenVideo, type ScreenView, type ViewOptions, codecFor } from "./source.ts";
import { DesktopWinInput } from "./win-input.ts";

export const SCREEN_BINARY = "comma-desktop-screen.exe";

/// The release's comma-desktop-screen: COMMA_STATION_DESKTOP_SCREEN (scripts/native.ts `run`), beside the station's code in a
/// release (scripts/bundle.sh), or built in the checkout.
export function screenBinary(env: NodeJS.ProcessEnv = process.env): string | null {
  const candidates = [
    env.COMMA_STATION_DESKTOP_SCREEN,
    fileURLToPath(new URL(`./${SCREEN_BINARY}`, import.meta.url)),
    fileURLToPath(new URL(`../../native/desktop-screen/target/release/${SCREEN_BINARY}`, import.meta.url)),
  ];
  return candidates.find((p) => p && existsSync(p)) ?? null;
}

/// This station's comma-desktop-screen where it serves the main display (Windows), else null: what the mesh's views
/// (mesh/mesh.ts) and the connector's `screen_view` capability go by.
export const windowsScreenBinary = (): string | null => (platform.hasWindowsScreen ? screenBinary() : null);

/// What `comma-desktop-screen status` says: the main display in pixels, and whether Windows can capture it (10 1903 on).
export type ScreenStatus = { display: { width: number; height: number }; capture: boolean };

/// How the process is started (a test's fake in tests).
export type Start = (binary: string, args: string[]) => ChildProcess;
const start: Start = (binary, args) => spawn(binary, args, { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });

export type WindowsDesktopOptions = {
  /// comma-desktop-screen, null when the release has none.
  binary: string | null;
  /// Told when its size changed.
  changed?: () => void;
  /// Its title (default: the machine's name).
  title?: () => string;
  start?: Start;
};

/// A status this recent is not asked again (unless forced).
const FRESH_MS = 2_000;

export class WindowsDesktop implements ScreenSource {
  /// The Mac's whole display is `display` too (helper.ts): a client opens the same id on either.
  readonly id = "display";
  readonly kind = "desktop" as const;
  /// H.265 where the client takes it and the hardware encodes it (its info says which it made), else H.264.
  readonly codecs: readonly Codec[] = ["h265", "h264"];
  readonly #o: WindowsDesktopOptions;
  readonly #views = new Set<LastingView>();
  #status: ScreenStatus | null = null;
  #looked = 0;
  #looking: Promise<void> | null = null;

  constructor(options: WindowsDesktopOptions) {
    this.#o = options;
  }

  title(): string {
    return this.#o.title?.() ?? hostname();
  }

  size(): { width: number; height: number } {
    return { width: this.#status?.display.width ?? 0, height: this.#status?.display.height ?? 0 };
  }

  /// Text and pictures, where the program is (still.fail win-desktop.ts `clipboard`).
  clipboard(): ClipType[] {
    return this.#o.binary === null ? [] : ["text", "png"];
  }

  /// The display's size as Windows has it now (at most a moment old, unless `force`).
  refresh(force = false): Promise<void> {
    if (this.#o.binary === null) return Promise.resolve();
    if (!force && wall.now() - this.#looked < FRESH_MS) return Promise.resolve();
    this.#looking ??= this.#ask(["status"])
      .then(
        (told) => {
          const status: ScreenStatus = { display: { width: Number(told.display?.width) || 0, height: Number(told.display?.height) || 0 }, capture: told.capture !== false };
          const before = this.#status;
          this.#status = status;
          if (before === null || before.display.width !== status.display.width || before.display.height !== status.display.height || before.capture !== status.capture) this.#o.changed?.();
        },
        (e) => log.warn("screens", "comma-desktop-screen did not say the display", { error: (e as Error).message }),
      )
      .finally(() => {
        this.#looked = wall.now();
        this.#looking = null;
      });
    return this.#looking;
  }

  /// What `comma-desktop-screen <args>` says (its one JSON line); throws what it said wrong.
  #ask(args: string[]): Promise<any> {
    const binary = this.#o.binary;
    if (binary === null) return Promise.reject(new Error("comma-desktop-screen is not there"));
    return new Promise((resolve, reject) => {
      const child = (this.#o.start ?? start)(binary, args);
      let said = "";
      const unarm = wall.after(10_000, () => child.kill());
      child.stdout!.setEncoding("utf8").on("data", (chunk: string) => (said += chunk));
      let finished = false;
      const done = (error?: Error) => {
        if (finished) return;
        finished = true;
        unarm();
        try {
          if (error) throw error;
          const told = JSON.parse(said);
          if (typeof told?.error === "string") throw new Error(told.error);
          resolve(told);
        } catch (e) {
          reject(e as Error);
        }
      };
      child.on("error", done);
      child.on("close", () => done());
      child.stdin?.end();
    });
  }

  async open(options: ViewOptions): Promise<ScreenView> {
    const binary = this.#o.binary;
    if (binary === null) throw new ScreenRefused(501, "station.screen.noHelper");
    const codec = codecFor(options, this.codecs);
    if (codec === undefined) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264" });
    await this.refresh();
    if (this.#status?.capture === false) throw new ScreenRefused(501, "station.screen.unsupported");
    const input = new DesktopWinInput();
    // The system output too, when the client asked for it (never a preview's): WASAPI's loopback (native/desktop-screen
    // audio.rs), as Opus where the client decodes it (opus.rs).
    const ask = { codec, ...(options.audio === true && !options.peek ? { audio: true, ...(options.opus ? { audioCodec: "opus" as const } : {}) } : {}), maxWidth: options.maxWidth, maxHeight: options.maxHeight, ...(options.bitrate ? { bitrate: Math.round(options.bitrate) } : {}) };
    let first: HelperView;
    try {
      first = await this.#start(binary, ask, input);
    } catch (error) {
      throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message });
    }
    const view: LastingView = new LastingView(first, () => this.#start(binary, ask, input), () => this.#views.delete(view));
    this.#views.add(view);
    return view;
  }

  /// One process for a view, answering (its info had); fails with what it said.
  async #start(binary: string, ask: { codec: Codec; maxWidth: number; maxHeight: number; bitrate?: number; audio?: boolean; audioCodec?: "opus" }, input: DesktopWinInput): Promise<HelperView> {
    const child = (this.#o.start ?? start)(binary, ["view"]);
    child.stdin!.write(`${JSON.stringify(ask)}\n`);
    const view = new HelperView(ask.codec, childPipe(child), () => {}, input, "Windows.Graphics.Capture", wall.now, ask.audio === true);
    try {
      await view.ready;
      return view;
    } catch (error) {
      view.close();
      throw error;
    }
  }

  /// The station stopping: every view ends.
  close(): Promise<void> {
    for (const view of [...this.#views]) view.close();
    return Promise.resolve();
  }
}

/// Started again this many times within RESTARTS_MS, a view ends instead (the display is not to be had).
const RESTARTS = 3;
const RESTARTS_MS = 60_000;

/// A view that outlives its process: one that ended without being asked (the display went or another became the main
/// one, the graphics driver started again, a crash) is started again, and the view goes on from a key frame with its
/// config (a client takes a new config at any frame), the clipboard still watched. Closed, or started again too often,
/// it ends as any view does.
export class LastingView implements ScreenView {
  #view: HelperView;
  readonly #again: () => Promise<HelperView>;
  readonly #gone: () => void;
  #closed = false;
  #restarts: number[] = [];
  /// The process being started again: every pending `next` waits for the one.
  #restarting: Promise<boolean> | null = null;
  /// Who hears the clipboard, heard again from a process started again.
  #heard: ((clip: Clip) => void) | null = null;
  #unwatch: (() => void) | null = null;
  /// Who hears the pointer, heard again from a process started again.
  #pointer: ((cursor: ScreenCursor) => void) | null = null;
  #unpoint: (() => void) | null = null;
  /// The bit rate and the bounds asked last, asked again of a process started again.
  #rate: number | null = null;
  #bounds: [number, number] | null = null;

  constructor(view: HelperView, again: () => Promise<HelperView>, gone: () => void) {
    this.#view = view;
    this.#again = again;
    this.#gone = gone;
  }

  async next(): Promise<Frame | null> {
    for (;;) {
      const view = this.#view;
      const frame = await view.next().catch((error: unknown) => {
        // Windows restarts its capture after an explicit stop as it does after process loss.
        if (error instanceof ScreenRefused) return null;
        throw error;
      });
      if (frame !== null || this.#closed) return frame;
      // Another `next` already started it again: this one asks the new process.
      if (this.#view === view && !(await (this.#restarting ??= this.#restart().finally(() => (this.#restarting = null))))) return null;
      if (this.#closed) return null;
    }
  }

  async nextAudio(): Promise<AudioFrame | null> {
    for (;;) {
      const view = this.#view;
      const audio = await view.nextAudio();
      if (audio !== null || this.#closed || !view.hasAudio()) return audio;
      if (this.#view === view && !(await (this.#restarting ??= this.#restart().finally(() => (this.#restarting = null))))) return null;
      if (this.#closed) return null;
    }
  }

  async #restart(): Promise<boolean> {
    const now = wall.now();
    this.#restarts = [...this.#restarts.filter((t) => now - t < RESTARTS_MS), now];
    if (this.#restarts.length > RESTARTS) {
      log.warn("screens", "comma-desktop-screen keeps ending; the view ends");
      this.close();
      return false;
    }
    try {
      const view = await this.#again();
      if (this.#closed) {
        view.close();
        return false;
      }
      log.info("screens", "comma-desktop-screen ended by itself; started again");
      this.#view = view;
      if (this.#heard !== null) this.#unwatch = view.watchClipboard(this.#heard);
      if (this.#pointer !== null) this.#unpoint = view.watchCursor(this.#pointer);
      if (this.#rate !== null) view.rate(this.#rate);
      if (this.#bounds !== null) view.bounds(...this.#bounds);
      return true;
    } catch (error) {
      log.warn("screens", "comma-desktop-screen did not start again", { error: (error as Error).message });
      this.close();
      return false;
    }
  }

  keyframe() {
    this.#view.keyframe();
  }

  rate(bitsPerSecond: number) {
    this.#rate = bitsPerSecond;
    this.#view.rate(bitsPerSecond);
  }

  bounds(maxWidth: number, maxHeight: number) {
    this.#bounds = [maxWidth, maxHeight];
    this.#view.bounds(maxWidth, maxHeight);
  }

  video(): ScreenVideo {
    return this.#view.video();
  }

  input(event: ScreenInput): Promise<void> {
    return this.#view.input(event);
  }

  setClipboard(clip: Clip, paste: boolean): Promise<void> {
    return this.#view.setClipboard(clip, paste);
  }

  watchClipboard(heard: (clip: Clip) => void): () => void {
    this.#heard = heard;
    this.#unwatch = this.#view.watchClipboard(heard);
    return () => {
      if (this.#heard !== heard) return;
      this.#heard = null;
      this.#unwatch?.();
      this.#unwatch = null;
    };
  }

  watchCursor(heard: (cursor: ScreenCursor) => void): () => void {
    this.#pointer = heard;
    this.#unpoint = this.#view.watchCursor(heard);
    return () => {
      if (this.#pointer !== heard) return;
      this.#pointer = null;
      this.#unpoint?.();
      this.#unpoint = null;
    };
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#view.close();
    this.#gone();
  }
}

/// A view's process as the helper's connection: its output read, its input written; destroyed, its input ends (the
/// process ends with it) and it is ended outright if it has not in a moment.
export function childPipe(child: ChildProcess): HelperPipe {
  const events = new EventEmitter();
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    events.emit("close");
  };
  child.stdout!.on("data", (chunk: Buffer) => events.emit("data", chunk));
  // Its output read to the end first: what it said as it went is had.
  child.on("close", close);
  child.on("error", (error) => {
    log.warn("screens", "comma-desktop-screen did not start", { error: error.message });
    close();
  });
  // Written to as it ends: nothing to be told.
  child.stdin!.on("error", () => {});
  return {
    write: (data) => child.stdin!.write(data),
    destroy() {
      child.stdin!.end();
      wall.after(2_000, () => {
        if (child.exitCode === null && child.signalCode === null) child.kill();
      });
    },
    on: (event: string, listener: (...args: any[]) => void) => events.on(event, listener),
  };
}
