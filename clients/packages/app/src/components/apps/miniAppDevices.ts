// The host side of a running app's device capabilities (microphone, location, screen, clipboard read, share, haptics,
// MIDI). The host page runs these SDK effects for the opaque frame, after the
// core allowed the op, and sends the app only the results: values, or the data of a stream over the frame's port.
// The camera's photo is taken in the host's camera sheet (MiniAppFrame), not here.

import type {
  MiniAppAudioInput,
  MiniAppMicrophoneChannelsOptions,
} from "@comma/chat-contract/mini-app-runtime";
import { nativePlatformClipboard } from "../../nativePlatformActions";

export type MiniAppDeviceResult =
  | { ok: true; value: unknown; transfer?: Transferable[] }
  | { ok: false; code: string; message: string };

/** The ops this class runs. */
export const MINI_APP_DEVICE_OPS = new Set([
  "microphone.devices",
  "microphone.watch",
  "microphone.start",
  "microphone.startChannels",
  "microphone.stop",
  "location.current",
  "screen.keepAwake",
  "screen.fullscreen",
  "clipboard.read",
  "share",
  "haptics",
  "midi.start",
  "midi.stop",
]);

/** A script processor needs no module of its own to load (the pages' CSP admits none); 2048 samples is 43 ms at 48 kHz. */
const MICROPHONE_CHUNK = 2048;
/** At most this many streams of one app at once. */
const MAX_STREAMS = 4;
const LOCATION_TIMEOUT_MS = 15_000;

type Send = (message: unknown, transfer?: Transferable[]) => void;

const unsupported = (message: string): MiniAppDeviceResult => ({
  ok: false,
  code: "unsupported",
  message,
});
const done = (value: unknown, transfer?: Transferable[]): MiniAppDeviceResult =>
  transfer ? { ok: true, value, transfer } : { ok: true, value };

/** The device use of one running app: everything it holds ends with `stop()`. */
export class MiniAppDevices {
  readonly #send: Send;
  readonly #container: () => HTMLElement | null;
  readonly #streams = new Map<number, () => void>();
  #serial = 0;
  #stopped = false;
  #awake = false;
  #wakeLock: WakeLockSentinel | undefined;

  constructor(send: Send, container: () => HTMLElement | null) {
    this.#send = send;
    this.#container = container;
  }

  async run(op: string, args: Record<string, unknown>): Promise<MiniAppDeviceResult> {
    switch (op) {
      case "microphone.devices":
        return this.#audioInputs();
      case "microphone.watch":
        return this.#watchAudioInputs();
      case "microphone.start":
        return this.#microphone(
          typeof args.deviceId === "string" ? args.deviceId : undefined
        );
      case "microphone.startChannels":
        return this.#microphone(
          typeof args.deviceId === "string" ? args.deviceId : undefined,
          args as unknown as MiniAppMicrophoneChannelsOptions
        );
      case "midi.start":
        return this.#midi();
      case "microphone.stop":
      case "midi.stop":
        this.#end(Number(args.stream), "stopped", false);
        return done(null);
      case "location.current":
        return location();
      case "screen.keepAwake":
        return this.#keepAwake(args.on === true);
      case "screen.fullscreen":
        return this.#fullscreen(args.on === true);
      case "clipboard.read":
        return done({ text: await nativePlatformClipboard.readText() });
      case "share":
        return share(args);
      case "haptics":
        if (typeof navigator.vibrate !== "function") return done({ played: false });
        return done({ played: navigator.vibrate(args.pattern as number[]) });
      default:
        return unsupported(`${op} is not available here.`);
    }
  }

  /** Ends every stream, the wake lock and full screen: the app stopped. */
  stop(): void {
    if (this.#stopped) return;
    this.#stopped = true;
    for (const stream of this.#streams.keys()) this.#end(stream, "stopped", false);
    this.#awake = false;
    document.removeEventListener("visibilitychange", this.#reacquire);
    void this.#wakeLock?.release().catch(() => undefined);
    this.#wakeLock = undefined;
    const container = this.#container();
    if (container && document.fullscreenElement === container)
      void document.exitFullscreen().catch(() => undefined);
  }

  #open(close: () => void): number {
    const stream = ++this.#serial;
    this.#streams.set(stream, close);
    return stream;
  }

  /** Ends `stream`; `tell` sends the app its end (the host ended it, not the app). */
  #end(stream: number, reason: string, tell: boolean): void {
    const close = this.#streams.get(stream);
    if (!close) return;
    this.#streams.delete(stream);
    close();
    if (tell && !this.#stopped) this.#send({ type: "stream-end", stream, reason });
  }

  async #audioInputs(): Promise<MiniAppDeviceResult> {
    if (!navigator.mediaDevices?.enumerateDevices)
      return unsupported("The microphone is not available here.");
    try {
      return done({ devices: await audioInputs() });
    } catch (error) {
      return mediaError(error, "microphone");
    }
  }

  async #watchAudioInputs(): Promise<MiniAppDeviceResult> {
    const media = navigator.mediaDevices;
    if (!media?.enumerateDevices)
      return unsupported("The microphone is not available here.");
    if (this.#streams.size >= MAX_STREAMS)
      return { ok: false, code: "rate_limited", message: "Too many open streams." };
    let devices: MiniAppAudioInput[];
    try {
      devices = await audioInputs();
    } catch (error) {
      return mediaError(error, "microphone");
    }
    if (this.#stopped)
      return { ok: false, code: "unavailable", message: "The app stopped." };
    // Each change lists the devices again; a list that ends after a newer one started is dropped.
    let serial = 0;
    const onChange = () => {
      const mine = ++serial;
      void audioInputs()
        .then((next) => {
          if (mine === serial && this.#streams.has(stream))
            this.#send({ type: "stream", stream, data: next });
        })
        .catch(() => undefined);
    };
    const stream = this.#open(() =>
      media.removeEventListener("devicechange", onChange)
    );
    media.addEventListener("devicechange", onChange);
    return done({ stream, devices });
  }

  async #microphone(
    deviceId: string | undefined,
    options?: MiniAppMicrophoneChannelsOptions
  ): Promise<MiniAppDeviceResult> {
    if (!navigator.mediaDevices?.getUserMedia)
      return unsupported("The microphone is not available here.");
    if (this.#streams.size >= MAX_STREAMS)
      return { ok: false, code: "rate_limited", message: "Too many open streams." };
    let media: MediaStream;
    try {
      // Raw audio: an app that tunes or measures pitch needs it unprocessed.
      media = await navigator.mediaDevices.getUserMedia({
        audio: {
          ...(deviceId === undefined ? {} : { deviceId: { exact: deviceId } }),
          channelCount: options ? { exact: options.channelCount } : 1,
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
        },
      });
    } catch (error) {
      return mediaError(error, "microphone");
    }
    if (this.#stopped) {
      for (const input of media.getTracks()) input.stop();
      return { ok: false, code: "unavailable", message: "The app stopped." };
    }
    const track = media.getAudioTracks()[0];
    const channelCount = options?.channelCount ?? 1;
    if (options && track?.getSettings().channelCount !== channelCount) {
      for (const input of media.getTracks()) input.stop();
      return unsupported(
        "The browser cannot confirm the requested input channel count."
      );
    }
    const channels =
      options?.channels ?? Array.from({ length: channelCount }, (_, index) => index);
    let context: AudioContext | undefined;
    let source: MediaStreamAudioSourceNode;
    let capture: ScriptProcessorNode;
    try {
      context = new AudioContext({ latencyHint: "interactive" });
      source = context.createMediaStreamSource(media);
      capture = context.createScriptProcessor(MICROPHONE_CHUNK, channelCount, 1);
      capture.channelCount = channelCount;
      capture.channelCountMode = "explicit";
      capture.channelInterpretation = "discrete";
      source.connect(capture);
      // A processor runs only while it leads somewhere; its output is silence.
      capture.connect(context.destination);
    } catch (error) {
      for (const input of media.getTracks()) input.stop();
      void context?.close().catch(() => undefined);
      return mediaError(error, "microphone");
    }
    const audio = context;
    const stream = this.#open(() => {
      capture.disconnect();
      source.disconnect();
      for (const input of media.getTracks()) input.stop();
      void audio.close().catch(() => undefined);
    });
    capture.addEventListener("audioprocess", (event) => {
      if (!this.#streams.has(stream)) return;
      if (options) {
        if (event.inputBuffer.numberOfChannels !== channelCount) {
          this.#end(stream, "unavailable", true);
          return;
        }
        const samples = channels.map((channel) =>
          event.inputBuffer.getChannelData(channel).slice()
        );
        this.#send(
          { type: "stream", stream, data: samples },
          samples.map((channel) => channel.buffer)
        );
      } else {
        const samples = event.inputBuffer.getChannelData(0).slice();
        this.#send({ type: "stream", stream, data: samples }, [samples.buffer]);
      }
    });
    // The device went away (unplugged, or the system took it back).
    for (const input of media.getTracks())
      input.addEventListener("ended", () => this.#end(stream, "ended", true), {
        once: true,
      });
    return done({
      stream,
      ...(options ? { channelCount, channels } : {}),
      sampleRate: audio.sampleRate,
      device: { id: track?.getSettings().deviceId ?? "", name: track?.label ?? "" },
    });
  }

  async #midi(): Promise<MiniAppDeviceResult> {
    if (typeof navigator.requestMIDIAccess !== "function")
      return unsupported("MIDI is not available here.");
    if (this.#streams.size >= MAX_STREAMS)
      return { ok: false, code: "rate_limited", message: "Too many open streams." };
    let access: MIDIAccess;
    try {
      access = await navigator.requestMIDIAccess({ sysex: false });
    } catch {
      return { ok: false, code: "denied", message: "MIDI is not allowed for Comma." };
    }
    if (this.#stopped)
      return { ok: false, code: "unavailable", message: "The app stopped." };
    const listened = new Set<MIDIInput>();
    const onMessage = (event: Event) => {
      const message = event as MIDIMessageEvent;
      const input = message.target as MIDIInput;
      if (!message.data || !this.#streams.has(stream)) return;
      const data = message.data.slice();
      this.#send(
        {
          type: "stream",
          stream,
          data: { input: input.id, data, time: message.timeStamp },
        },
        [data.buffer]
      );
    };
    const listen = () => {
      for (const input of access.inputs.values())
        if (!listened.has(input)) {
          listened.add(input);
          input.addEventListener("midimessage", onMessage);
        }
    };
    const stream = this.#open(() => {
      access.removeEventListener("statechange", listen);
      for (const input of listened) input.removeEventListener("midimessage", onMessage);
      listened.clear();
    });
    listen();
    // A device plugged in later is heard too.
    access.addEventListener("statechange", listen);
    return done({
      stream,
      inputs: [...access.inputs.values()].map((input) => ({
        id: input.id,
        name: input.name ?? "",
      })),
    });
  }

  async #keepAwake(on: boolean): Promise<MiniAppDeviceResult> {
    if (!("wakeLock" in navigator))
      return unsupported("Keeping the screen on is not available here.");
    this.#awake = on;
    if (!on) {
      document.removeEventListener("visibilitychange", this.#reacquire);
      const held = this.#wakeLock;
      this.#wakeLock = undefined;
      await held?.release().catch(() => undefined);
      return done(null);
    }
    document.addEventListener("visibilitychange", this.#reacquire);
    try {
      await this.#acquire();
    } catch {
      this.#awake = false;
      return {
        ok: false,
        code: "failed",
        message: "The screen cannot be kept on now.",
      };
    }
    return done(null);
  }

  async #acquire(): Promise<void> {
    if (this.#wakeLock && !this.#wakeLock.released) return;
    const lock = await navigator.wakeLock.request("screen");
    if (!this.#awake || this.#stopped) {
      await lock.release();
      return;
    }
    this.#wakeLock = lock;
  }

  /** The system releases a wake lock when the page is hidden: take it again when it shows. */
  readonly #reacquire = () => {
    if (this.#awake && !this.#stopped && document.visibilityState === "visible")
      void this.#acquire().catch(() => undefined);
  };

  async #fullscreen(on: boolean): Promise<MiniAppDeviceResult> {
    const container = this.#container();
    if (!container || !document.fullscreenEnabled)
      return unsupported("Full screen is not available here.");
    try {
      if (on) {
        if (document.fullscreenElement !== container)
          await container.requestFullscreen();
      } else if (document.fullscreenElement === container)
        await document.exitFullscreen();
    } catch {
      // Without the viewer's click or key press just before, the browser refuses it.
      return {
        ok: false,
        code: "denied",
        message: "Full screen needs a click or a key press.",
      };
    }
    return done(null);
  }
}

const listAudioInputs = async () =>
  (await navigator.mediaDevices.enumerateDevices()).filter(
    (device) => device.kind === "audioinput"
  );

/**
 * The audio inputs. Before the page may use the microphone the browser hides their IDs and names, so it asks for the
 * microphone once (the app already holds the grant) and lists them again.
 */
async function audioInputs(): Promise<MiniAppAudioInput[]> {
  let devices = await listAudioInputs();
  if (devices.length > 0 && devices.every((device) => !device.label)) {
    const media = await navigator.mediaDevices.getUserMedia({ audio: true });
    for (const input of media.getTracks()) input.stop();
    devices = await listAudioInputs();
  }
  return devices.map((device) => {
    const capabilities =
      "getCapabilities" in device ? (device as InputDeviceInfo).getCapabilities() : {};
    const channelCount = audioRange(capabilities.channelCount);
    const sampleRate = audioRange(capabilities.sampleRate);
    return {
      id: device.deviceId,
      name: device.label,
      ...(channelCount ? { channelCount } : {}),
      ...(sampleRate ? { sampleRate } : {}),
    };
  });
}

function audioRange(
  range: ULongRange | undefined
): { min: number; max: number } | undefined {
  return range?.min !== undefined && range.max !== undefined
    ? { min: range.min, max: range.max }
    : undefined;
}

function mediaError(error: unknown, device: string): MiniAppDeviceResult {
  const name = error instanceof DOMException ? error.name : "";
  if (name === "NotAllowedError" || name === "SecurityError")
    return {
      ok: false,
      code: "denied",
      message: `The ${device} is not allowed for Comma.`,
    };
  if (name === "NotReadableError")
    return {
      ok: false,
      code: "unavailable",
      message: `The ${device} is in use or cannot be read.`,
    };
  if (name === "OverconstrainedError")
    return {
      ok: false,
      code: "unavailable",
      message: `The requested ${device} settings are not available.`,
    };
  if (name === "NotFoundError")
    return { ok: false, code: "unavailable", message: `There is no ${device}.` };
  return { ok: false, code: "failed", message: `The ${device} could not start.` };
}

/** This device's position, once; the browser asks the person first. */
export function location(): Promise<MiniAppDeviceResult> {
  if (!("geolocation" in navigator))
    return Promise.resolve(unsupported("Location is not available here."));
  return new Promise((resolve) =>
    navigator.geolocation.getCurrentPosition(
      (position) =>
        resolve(
          done({
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
            accuracy: position.coords.accuracy,
            at: new Date(position.timestamp).toISOString(),
          })
        ),
      (error) =>
        resolve(
          error.code === error.PERMISSION_DENIED
            ? {
                ok: false,
                code: "denied",
                message: "Location is not allowed for Comma.",
              }
            : {
                ok: false,
                code: "unavailable",
                message: "The location is not known now.",
              }
        ),
      { enableHighAccuracy: true, timeout: LOCATION_TIMEOUT_MS, maximumAge: 60_000 }
    )
  );
}

async function share(args: Record<string, unknown>): Promise<MiniAppDeviceResult> {
  if (typeof navigator.share !== "function")
    return unsupported("Sharing is not available here.");
  const content: ShareData = {};
  if (typeof args.title === "string") content.title = args.title;
  if (typeof args.text === "string") content.text = args.text;
  if (typeof args.url === "string") content.url = args.url;
  try {
    await navigator.share(content);
    return done({ shared: true });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError")
      return done({ shared: false });
    // Without the viewer's click just before, the browser refuses it.
    return {
      ok: false,
      code: "denied",
      message: "Sharing needs a click or a key press.",
    };
  }
}
