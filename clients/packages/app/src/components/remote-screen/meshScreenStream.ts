import type { ScreenClip, ScreenViewEvent } from "@comma/core/contract";
import { uiClock } from "@comma/ui/clock";
import {
  askedCodecs,
  createScreenDecoder,
  supports,
  type ScreenDecoder,
} from "./screenDecoder";
import { createScreenOpusDecoder, type ScreenOpusDecoder } from "./screenAudio";
import type { ScreenDeviceState } from "./screenDevice";
import { SCREEN_DECODER_UNSUPPORTED, screenFailureKind } from "./screenFailure";
import type { ScreenStreamInput } from "./screenStreamInput";
import type {
  ScreenAgentPointer,
  ScreenCursor,
  ScreenStreamStats,
} from "./screenStreamStats";

export type ScreenStreamState = "connecting" | "live" | "failed";

/** An open view, as its holders use it. */
export type ScreenStreamPeer = {
  /** Sends one input event. */
  send(input: ScreenStreamInput): void;
  /** Shows the last frame again, for a `<video>` that came to the stream since: a still source sends no other. */
  repaint?(): void;
  /**
   * Watch or Control on the open view, the picture going on as it was: false where it cannot (a station from before),
   * which takes a view of its own.
   */
  control?(on: boolean): boolean;
  /** Sets the screen's clipboard and, with `paste`, pastes it there (while the view drives). */
  setClipboard?(clip: ScreenClip, paste: boolean): void;
  /** The view's sound off (muted here: the computer sends none) or on again. */
  sound?(on: boolean): void;
  close(): void;
};

/** A view of a computer's screen over the mesh: what it says as it goes; it runs until `signal` ends it or it fails. */
export type ScreenViewOpen = (
  onEvent: (event: ScreenViewEvent) => void,
  signal: AbortSignal,
  /** What this page decodes, the one it would rather have first. */
  codecs: readonly string[],
  /** Whether it drives from its start. */
  control: boolean
) => Promise<unknown>;

/** What a view's page says to it. */
export type ScreenViewMessage =
  | { ack: number; timing?: ScreenFrameTiming }
  | { keyframe: true }
  | { input: ScreenStreamInput }
  | { control: boolean }
  | { clipboard: ScreenClip; paste: boolean }
  | { sound: boolean };

/** Ms from the page having a frame to its decoder taking it, giving it out, it handed to the track, its `ack`. */
export type ScreenFrameTiming = {
  decodeIn?: number;
  decodeOut?: number;
  shown?: number;
  ack?: number;
};
// Frames whose times are kept, at most, until their `ack`.
const MAX_TIMED = 240;

// A failure with one of these codes means the mesh is not the way to this screen: not that the screen cannot be shown.
const NOT_HERE = new Set([
  "unsupported",
  "unreachable",
  "unavailable",
  "timeout",
  // A core from before these views.
  "unknown_call",
]);

// Chromium's, on a page's main thread; not in TypeScript's DOM types.
declare const MediaStreamTrackGenerator:
  | (new (init: { kind: "video" }) => MediaStreamTrack & {
      writable: WritableStream<VideoFrame>;
    })
  | undefined;

/** Where decoded frames go to be a `<video>`'s stream. Each frame written is the track's to close. */
type FrameTrack = {
  stream: MediaStream;
  write(frame: VideoFrame): void;
  close(): void;
};

/**
 * A track of written frames: Chromium's generator, else (Safari, Firefox) a canvas each frame is drawn on, whose
 * captured stream sends a frame as each is drawn.
 */
function frameTrack(): FrameTrack {
  if (typeof MediaStreamTrackGenerator !== "undefined") {
    const generator = new MediaStreamTrackGenerator({ kind: "video" });
    const writer = generator.writable.getWriter();
    return {
      stream: new MediaStream([generator]),
      write: (frame) => void writer.write(frame).catch(() => undefined),
      close: () => void writer.close().catch(() => undefined),
    };
  }
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");
  const stream = canvas.captureStream(0);
  const track = stream.getVideoTracks()[0] as
    | (MediaStreamTrack & { requestFrame?(): void })
    | undefined;
  return {
    stream,
    write: (frame) => {
      if (
        canvas.width !== frame.displayWidth ||
        canvas.height !== frame.displayHeight
      ) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      context?.drawImage(frame, 0, 0);
      frame.close();
      track?.requestFrame?.();
    },
    close: () => track?.stop(),
  };
}

/** Whether this page can turn decoded frames into a stream. */
const tracksFrames = () =>
  typeof MediaStreamTrackGenerator !== "undefined" ||
  (typeof document !== "undefined" &&
    typeof HTMLCanvasElement !== "undefined" &&
    "captureStream" in HTMLCanvasElement.prototype);

// A view that went after it showed comes back by itself, after each of these; the picture stays meanwhile.
const AGAIN_AFTER_MS = [500, 1000, 2000, 4000, 8000];
// The station says it is alive every 2 s: this long of hearing nothing, what shows is no longer live.
const SILENT_AFTER_MS = 5000;
const nothing: () => void = () => undefined;

/** Whether this page decodes `codec` (a decoder that does not say within its time does not). */
function decodes(codec: string): Promise<boolean> {
  return supports({
    codec,
    codedWidth: 1920,
    codedHeight: 1080,
    optimizeForLatency: true,
  });
}

/** The codecs this page decodes and can show as a stream, the one it would rather have first: H.265, then H.264. */
async function decodable(): Promise<string[]> {
  if (typeof VideoDecoder === "undefined" || !tracksFrames()) return [];
  const [h265, h264] = await Promise.all([
    decodes("hvc1.1.6.L120.B0"),
    decodes("avc1.42E02A"),
  ]);
  return [...(h265 ? ["h265"] : []), ...(h264 ? ["h264"] : [])];
}

/**
 * Shows a view of a computer's screen: the core has its frames from the station over the mesh, WebCodecs decodes them
 * here and the stream `onStream` gives carries them, so a `<video>` shows them. Each frame
 * shown is acknowledged, which is what the station paces the next by. `onUnavailable` runs when this page, this app or
 * the computer has no such views, or the mesh does not reach it, before anything was shown: another way may.
 */
export function openMeshScreenStream(options: {
  /** Whether it drives as it opens (none: it watches); `control` changes it on the open view. */
  control?: boolean;
  open: ScreenViewOpen;
  send(view: number, message: ScreenViewMessage): void;
  onStream(stream: MediaStream): void;
  onState(state: ScreenStreamState): void;
  /** What it says, and its code when it has one: the code says whether trying again can help. */
  onFailure(message: string, code?: string): void;
  onUnavailable(): void;
  /** The apps it really shows, and how many of their windows are on screen. */
  onTarget?(target: { apps: readonly string[]; windows: number }): void;
  /** How a device stands, as that changes. */
  onDevice?(stands: ScreenDeviceState): void;
  /** The computer did not let it drive, and why. */
  onRefused?(why: string): void;
  /**
   * A switch asked while the view opened did not reach it: its station is from before, and keeps what the view opened
   * with until a view opens anew.
   */
  onSwitchLost?(): void;
  /** The screen's pointer as it moves, where the station draws it apart from the picture. */
  onCursor?(cursor: ScreenCursor): void;
  /** Whether an agent's lease on the device lasts, as the station says it after each view's first state. */
  onAgent?(on: boolean): void;
  /** Where that agent's finger is as it acts. */
  onAgentPointer?(at: ScreenAgentPointer): void;
  /** What the statistics show as it changes: the picture's codec and size, how it is made, how late it is. */
  onStats?(stats: Omit<ScreenStreamStats, "frames" | "bytes">): void;
  /** A frame came, of so many bytes (the statistics' frame rate and bandwidth). */
  onFrame?(bytes: number): void;
  /** A view opened: the clipboard's types it carries while it drives (none: no clipboard). */
  onClipboardTypes?(types: readonly ("text" | "png")[]): void;
  /** A copy made on the screen, while this view drives it. */
  onClipboard?(clip: ScreenClip): void;
  /**
   * One packet of the screen's system output as PCM16 (after its format was said; Opus decoded first); null: the view
   * went, what plays stops.
   */
  onAudio?(data: Uint8Array | null): void;
  /** Whether the sound is on here (not muted): a view opens told so. None: on. */
  sound?(): boolean;
  /** The view carries the screen's sound (its format was said), muted here or not. */
  onSound?(): void;
}): ScreenStreamPeer {
  const stop = new AbortController();
  let closed = false;
  let view: number | undefined;
  // Watch or Control: what is asked now, and what the open view was asked as it opened.
  let control = options.control === true;
  let opened = control;
  // Whether the station switches on the open view; one from before says nothing of it, and takes Control only at open.
  let switches: boolean | undefined;
  let shown = false;
  let live = false;
  let decoder: ScreenDecoder | undefined;
  // This view ends for its decoder: the stream opens another, at once (H.265 no longer asked) or after a wait.
  let reopen: { message: string; now: boolean } | undefined;
  let attempt: AbortController | undefined;
  let writer: FrameTrack | undefined;
  // The last frame shown, one decoder buffer: a `<video>` that comes to the stream later shows nothing until a frame
  // is written, and a still screen sends none.
  let last: VideoFrame | undefined;
  let tries = 0;
  // Only a station that says it is alive can be heard going silent: from another, a still screen would look dead.
  let says = false;
  let heard = uiClock.now();
  let silent = false;
  let cancelWatch = nothing;
  const watch = () => {
    cancelWatch = uiClock.after(1000, () => {
      if (closed) return;
      if (says && live && uiClock.now() - heard > SILENT_AFTER_MS) {
        silent = true;
        live = false;
        options.onState("connecting");
      }
      watch();
    });
  };
  watch();

  // The format of the sound was said on the view that runs: only then are its packets played (Opus's decoded first).
  let audible = false;
  let opus: ScreenOpusDecoder | undefined;
  const end = () => {
    if (audible) options.onAudio?.(null);
    audible = false;
    opus?.close();
    opus = undefined;
    decoder?.reset();
    decoder = undefined;
    writer?.close();
    writer = undefined;
    last?.close();
    last = undefined;
  };
  const fail = (message: string, code?: string) => {
    if (closed) return;
    closed = true;
    cancelWatch();
    end();
    stop.abort();
    options.onFailure(message, code);
    options.onState("failed");
  };

  const reopenFor = (message: string, now: boolean) => {
    reopen = { message, now };
    attempt?.abort();
  };

  // A station that logs its frames' times (its state's `timing`): when each was had, given to the decoder, out of it and
  // handed to the track, on the page's clock, said with its `ack`.
  let timing = false;
  const times = new Map<
    number,
    { got: number; decodeIn?: number; decodeOut?: number; shown?: number }
  >();
  const timed = (ts: number, stage: "decodeIn" | "decodeOut" | "shown") => {
    const t = times.get(ts);
    if (t) t[stage] = uiClock.monotonic() - t.got;
  };
  // Its frames' acknowledgements say processed or dropped, not displayed (screenDecoder.ts).
  const ack = (ts: number) => {
    if (view === undefined) return;
    const t = times.get(ts);
    for (const at of times.keys()) if (at <= ts) times.delete(at);
    if (!t) return options.send(view, { ack: ts });
    const { got, ...stages } = t;
    options.send(view, {
      ack: ts,
      timing: { ...stages, ack: uiClock.monotonic() - got },
    });
  };
  const ensureDecoder = (): ScreenDecoder => {
    if (!writer) {
      writer = frameTrack();
      options.onStream(writer.stream);
    }
    decoder ??= createScreenDecoder({
      frame: (frame) => {
        const ts = frame.timestamp;
        if (closed || !writer) {
          frame.close();
          return;
        }
        timed(ts, "decodeOut");
        last?.close();
        last = frame.clone();
        // The track closes the frame.
        writer.write(frame);
        timed(ts, "shown");
        shown = true;
        if (!live) {
          live = true;
          options.onState("live");
        }
        tries = 0;
        ack(ts);
      },
      letGo: ack,
      decoding: (ts) => timed(ts, "decodeIn"),
      keyframe: () => {
        if (view !== undefined) options.send(view, { keyframe: true });
      },
      reopen: (message, now) => {
        if (!closed) reopenFor(message, now);
      },
    });
    return decoder;
  };

  const onEvent = (event: ScreenViewEvent) => {
    if (closed) return;
    heard = uiClock.now();
    if (silent) {
      silent = false;
      if (shown) {
        live = true;
        options.onState("live");
      }
    }
    if (event.type === "state") {
      if (event.state.alive) says = true;
      if (event.state.timing === true) timing = true;
      if (switches === undefined && event.state.control !== undefined) {
        switches = event.state.switches === true;
        // Switched while it opened: said now that the view runs.
        if (control !== opened) {
          if (!switches) options.onSwitchLost?.();
          else if (view !== undefined) options.send(view, { control });
        }
      }
      if (event.state.refused) options.onRefused?.(event.state.refused);
      if (event.state.apps)
        options.onTarget?.({
          apps: event.state.apps,
          windows: event.state.windows ?? 1,
        });
      if (event.state.orientation !== undefined || event.state.pose !== undefined)
        options.onDevice?.({
          orientation: event.state.orientation,
          pose: event.state.pose,
        });
      if (event.state.cursor) options.onCursor?.(event.state.cursor);
      if (event.state.agent !== undefined) options.onAgent?.(event.state.agent);
      if (event.state.agentPointer) options.onAgentPointer?.(event.state.agentPointer);
      if (event.state.video) options.onStats?.({ video: event.state.video });
      if (event.state.latency) options.onStats?.({ latency: event.state.latency });
      return;
    }
    // (the statistics' figures, apart from the decoder's path)
    if (event.type === "config")
      options.onStats?.({
        codec: event.codec,
        width: event.width,
        height: event.height,
      });
    else if (event.type === "video") options.onFrame?.(event.data.byteLength);
    if (event.type === "clipboard") {
      options.onClipboard?.(event.clip);
      return;
    }
    if (event.type === "audioConfig") {
      opus?.close();
      opus = undefined;
      if (event.codec === "opus") {
        if (typeof AudioDecoder === "undefined") return;
        opus = createScreenOpusDecoder((pcm) => {
          if (audible && !closed) options.onAudio?.(pcm);
        });
      }
      audible = true;
      options.onSound?.();
      return;
    }
    if (event.type === "audio") {
      if (!audible) return;
      if (opus) opus.decode(event.ts, event.data);
      else options.onAudio?.(event.data);
      return;
    }
    if (event.type === "open") {
      view = event.view;
      if (options.sound?.() === false) options.send(view, { sound: false });
      timing = false;
      times.clear();
      options.onClipboardTypes?.(event.clipboard ?? []);
    } else if (event.type === "config") ensureDecoder().configure(event);
    else if (event.type === "video") {
      if (timing) {
        times.set(event.ts, { got: uiClock.monotonic() });
        if (times.size > MAX_TIMED) times.delete(times.keys().next().value!);
      }
      if (decoder) decoder.decode(event);
      else ack(event.ts);
    }
  };

  void (async () => {
    const codecs = await decodable();
    if (codecs.length === 0) {
      // No way to show a screen on this page: said so once, not tried again.
      fail("This page cannot decode a screen.", SCREEN_DECODER_UNSUPPORTED);
      return;
    }
    for (;;) {
      if (closed) return;
      const asked = askedCodecs(codecs);
      let failure: unknown = new Error("The screen stopped.");
      const current = new AbortController();
      attempt = current;
      const abort = () => current.abort();
      stop.signal.addEventListener("abort", abort, { once: true });
      switches = undefined;
      opened = control;
      try {
        if (asked.length === 0) throw failure;
        // A view this stream ended says nothing more to it.
        await options.open(
          (event) => {
            if (!current.signal.aborted) onEvent(event);
          },
          current.signal,
          asked,
          control
        );
      } catch (error) {
        failure = error;
      }
      stop.signal.removeEventListener("abort", abort);
      if (closed) return;
      view = undefined;
      // The view's decoder goes with it (the picture stays): the next view's config makes another. Its sound stops,
      // and its clipboard is no longer carried, until the next view says.
      decoder?.reset();
      if (audible) options.onAudio?.(null);
      audible = false;
      options.onClipboardTypes?.([]);
      const decoding = reopen;
      reopen = undefined;
      const code = decoding ? undefined : (failure as { code?: unknown }).code;
      if (!decoding && !shown && typeof code === "string" && NOT_HERE.has(code)) {
        closed = true;
        end();
        options.onUnavailable();
        return;
      }
      // It was showing: the connection went (a blip, its credential's end). A refusal to the next view ends this.
      // Its decoder failed: another view, with another codec or after a wait, can show it.
      const again = decoding?.now
        ? 0
        : (decoding ??
            (shown &&
              screenFailureKind(typeof code === "string" ? code : undefined) !==
                "refused"))
          ? AGAIN_AFTER_MS[tries]
          : undefined;
      if (again === undefined) {
        fail(
          decoding?.message ??
            (failure instanceof Error ? failure.message : String(failure)),
          typeof code === "string" ? code : undefined
        );
        return;
      }
      if (again > 0) tries++;
      live = false;
      silent = false;
      says = false;
      options.onState("connecting");
      if (again > 0)
        await new Promise<void>((resolve) => {
          const cancel = uiClock.after(again, resolve);
          stop.signal.addEventListener("abort", () => (cancel(), resolve()), {
            once: true,
          });
        });
    }
  })();

  return {
    send(input) {
      if (view !== undefined) options.send(view, { input });
    },
    setClipboard(clip, paste) {
      if (view !== undefined) options.send(view, { clipboard: clip, paste });
    },
    sound(on) {
      if (view !== undefined) options.send(view, { sound: on });
    },
    control(on) {
      if (switches === false) return false;
      control = on;
      // (a view not open yet opens as it is asked now, or is told once it says it switches)
      if (view !== undefined && switches) options.send(view, { control: on });
      return true;
    },
    repaint() {
      if (!last || !writer) return;
      // (a later time than it had: a track lets no frame through at a time it has shown)
      const again = new VideoFrame(last, { timestamp: last.timestamp + 1 });
      last.close();
      last = again;
      writer.write(again.clone());
    },
    close() {
      closed = true;
      end();
      stop.abort();
    },
  };
}
