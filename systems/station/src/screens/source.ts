// What a person can see and drive on this station: the machine's windows and display, from its Computer Use helper
// (macOS: screens/helper.ts) or comma-desktop-screen (Windows' main display: screens/win-desktop.ts), its Android emulators (screens/android.ts) and a Mac's iOS Simulators (screens/simulator.ts). A source opens views; a view is pull-driven (`next` gives a frame only when asked), so a slow link lowers the frame rate
// instead of queueing frames. The mesh layer carries views (mesh/screens.ts, `/screens`); sources know nothing of it.

import type { Clip, ClipType, ScreenAudioCodec } from "@comma/mesh";
import type { AppLogs } from "./app-logs.ts";
import type { ChromeSource } from "./sim-chrome.ts";

export type Codec = "h264" | "h265" | "jpeg";

/// What a screen's clipboard holds, as a view carries it (@comma/mesh's screen-wire.ts, still.fail's source.ts).
export type { Clip, ClipType };

/// One packet of system output: 20 ms of 48 kHz stereo PCM16 (3840 bytes), stamped with its capture time (µs).
/// still.fail's source.ts `AudioFrame`.
/// `codec`: PCM16's 3840 bytes, or one Opus packet (a source asked `opus` that encodes it).
export type AudioFrame = { ts: number; data: Uint8Array; codec: ScreenAudioCodec };

/// A frame's format: sent before the first frame and whenever it changes; the next frame is then a key frame.
/// `description`: H.264's avcC or H.265's hvcC, what WebCodecs takes as the decoder's configuration; none for JPEG.
export type FrameConfig = { codec: Codec; width: number; height: number; description?: Uint8Array };

/// One encoded frame: H.264 or H.265 as length-prefixed NAL units (AVCC, HVCC), or one whole JPEG. `ts`: microseconds, rising.
/// `timing`: of a view opened `timing` (mesh/screen-timing.ts).
export type Frame = { config?: FrameConfig; key: boolean; ts: number; data: Uint8Array; timing?: HelperTiming };

/// A frame's times, in ms on the host's clock (mesh/screen-pace.ts `hostNow`): the helper's encoder took it and gave it
/// out, the helper sent it (none: a helper from before, or one that does not say), the station had it.
export type HelperTiming = { encodeStart?: number; encodeDone?: number; sent?: number; got: number };

export type DevicePose = "closed" | "book" | "open";

/// A touchscreen's input; coordinates are 0..1 of the picture. `mods`: bit 0 alt, 1 ctrl, 2 meta, 3 shift.
export type DeviceInput =
  | { t: "pointer"; kind: "down" | "up" | "move"; x: number; y: number; buttons: number }
  | { t: "wheel"; x: number; y: number; dx: number; dy: number }
  | { t: "key"; kind: "down" | "up"; key: string; code: string; mods: number }
  /// Text an IME composed or a paste carried (still.fail's `{t:"text"}`, its docs/remote-screens.md input message).
  | { t: "text"; text: string }
  /// A foldable's hinge, to one of `ScreenSource.poseNames`.
  | { t: "pose"; name: DevicePose }
  | { t: "device"; name: "volume_up" | "volume_down" | "rotate" }
  /// One of a simulator's hardware buttons by its HID usage (`ScreenSource.chrome`), as it goes down and comes up.
  | { t: "button"; page: number; usage: number; down: boolean };

/// One input event as a source takes it: each source adapts the wire's form to its own (`mesh/screens.ts helperInput`, `deviceInput`).
export type ScreenInput = { type: string; [field: string]: unknown } | DeviceInput;

/// How a device stands, as far as it says: which way it is turned, a foldable's pose.
export type DeviceStands = { orientation?: 0 | 90 | 180 | 270; pose?: DevicePose };

/// A panel of a device's screen, its corners' radii as shares of its width, top left and then round it. `curves`, where
/// the shape is known closer (a simulator's mask: sim-mask.ts): each corner as CSS's `superellipse(k)` on a radius of
/// `reach`, a share of the width.
export type Panel = {
  width: number;
  height: number;
  corners: [number, number, number, number];
  curves?: [PanelCurve, PanelCurve, PanelCurve, PanelCurve];
};
export type PanelCurve = { reach: number; k: number };

/// `bitrate`: what to encode at first (bits a second; none: the source's own), until `ScreenView.rate` says otherwise.
/// `peek`: a preview (a link's card): it wakes nothing, only looks, and comes small and about twice a second. Asked only
/// of one that says `peek`.
/// `cursor`: the pointer left out of the pictures and said apart (`ScreenView.watchCursor`), where the source can: a view
/// whose client draws it. Not asked, it stays in the pictures.
/// `audio`: the machine's system output too (never a microphone's), where the source captures it (`ScreenView.nextAudio`);
/// never a preview's (still.fail's `ViewOptions.audio`).
/// `opus`: the client takes the sound as Opus, where the source encodes it (else PCM).
export type ViewOptions = { maxWidth: number; maxHeight: number; codecs: Codec[]; bitrate?: number; peek?: boolean; cursor?: boolean; audio?: boolean; opus?: boolean; timing?: boolean };

/// How a view's pictures are made, for the viewer's statistics (still.fail's `ScreenVideo`): what captures them, the
/// encoder as it names itself, and whether that is the hardware's.
export type ScreenVideo = { capture: string; encoder?: string; hardware?: boolean };

/// Where a screen's pointer is, 0..1 of the picture, and its shape as CSS names it (`none`: hidden). still.fail's
/// `ScreenCursor`.
export type ScreenCursor = { x: number; y: number; shape: string };

/// What an app's view shows: its real names, and how many of its windows are on screen.
export type ScreenTargetInfo = { apps: string[]; windows: number };

/// What a source says of an agent's lease on it, for those who look at it meanwhile: whether one lasts (`agent`), and
/// where the agent's finger is as it presses, moves and lifts (`agentPointer`: 0..1 of the picture, as a person's input).
export type AgentSaid = { agent: boolean } | { agentPointer: { x: number; y: number; down: boolean } };

/// An agent's lease on a device, and those who look at the device meanwhile (`ScreenSource.watchAgent`): they hear a
/// lease start and end, and where the agent's finger is as it acts.
export class AgentPresence {
  #lease: string | null = null;
  readonly #heard = new Set<(said: AgentSaid) => void>();

  /// What the lease says while it lasts; null: none.
  get lease(): string | null {
    return this.#lease;
  }

  set lease(next: string | null) {
    const was = this.#lease !== null;
    this.#lease = next;
    if (was !== (next !== null)) this.#tell({ agent: next !== null });
  }

  /// Hears it, at once with whether a lease lasts now; until the returned function.
  watch(heard: (said: AgentSaid) => void): () => void {
    this.#heard.add(heard);
    heard({ agent: this.#lease !== null });
    return () => void this.#heard.delete(heard);
  }

  /// Where the agent's finger is now (0..1 of the picture), and whether it is down.
  points(at: { x: number; y: number }, down: boolean) {
    this.#tell({ agentPointer: { x: at.x, y: at.y, down } });
  }

  #tell(said: AgentSaid) {
    for (const heard of [...this.#heard]) heard(said);
  }
}

export interface ScreenView {
  /// What it shows, for a target that picks an app. Absent for a whole display.
  target?(): ScreenTargetInfo | null;
  /// Told when that changes; the returned function stops it.
  onTarget?(listener: () => void): () => void;
  /// The next frame once there is a new one, or null when the view ended (the source went away).
  /// A capture refusal rejects with ScreenRefused so the viewer can show its reason.
  next(): Promise<Frame | null>;
  /// Starts the next frame as a key frame (a client's decoder lost its state).
  keyframe(): void;
  input(event: ScreenInput): Promise<void>;
  /// Encodes from the next frame at about this many bits a second (the link carries no more).
  rate?(bitsPerSecond: number): void;
  /// The pictures from now on fitted into these bounds (still.fail's `bounds`: a slow link's smaller picture,
  /// mesh/screen-pace.ts `Sizer`).
  bounds?(maxWidth: number, maxHeight: number): void;
  /// Hears how a device stands as that changes, until the returned function.
  watchDevice?(heard: (stands: DeviceStands) => void): () => void;
  /// How its pictures are made, once it knows (an encoder may be made with its first picture, and anew for a new size);
  /// none: not said.
  video?(): ScreenVideo | null;
  /// Hears where the pointer is and its shape as it moves or changes (and the last said, at once), until the returned
  /// function, as still.fail's source.ts `watchCursor`: a source whose pictures leave the pointer out (Windows' desktop
  /// video; the helper's desktop, asked `cursor`) says it so; one without it draws it in its pictures, or has none.
  watchCursor?(heard: (cursor: ScreenCursor) => void): () => void;
  /// The next packet of the system output it was opened with (`ViewOptions.audio`), once there is one; null when it has
  /// none, or no more (still.fail's `nextAudio`). One is asked at a time.
  nextAudio?(): Promise<AudioFrame | null>;
  /// The source's clipboard set (of a type its `clipboard()` names), then, with `paste`, pasted where its focus is (the
  /// machine's paste key). Only a view a person drives now is asked (still.fail's `setClipboard`).
  setClipboard?(clip: Clip, paste: boolean): Promise<void>;
  /// Hears the source's clipboard each time it changes (a copy made on it; not what it holds as this starts), until the
  /// returned function. Only a view a person drives is asked, for as long as it drives (still.fail's `watchClipboard`).
  watchClipboard?(heard: (clip: Clip) => void): () => void;
  /// Stops capturing; a pending `next` resolves null.
  close(): void;
}

/// The codec a view gets of a source that makes `own` (the one it would rather first): the first the view takes. still.fail's
/// source.ts `codecFor`, without its preview's JPEG (no desktop here offers a preview).
export function codecFor(options: Pick<ViewOptions, "codecs">, own: readonly Codec[]): Codec | undefined {
  return own.find((c) => options.codecs.includes(c));
}

/// What it is: a device's id says so too (`android:<serial>`, `simulator:<udid>`).
export type ScreenKind = "desktop" | "android" | "simulator";

/// One of a computer's devices, which only a listing that asks for them shows, and which views and closes by its instance.
export const isDevice = (source: Pick<ScreenSource, "kind">): boolean => source.kind === "android" || source.kind === "simulator";

export interface ScreenSource {
  /// `app` (an app's windows), `display` or `android:<serial>`.
  readonly id: string;
  readonly kind: ScreenKind;
  /// It can be previewed (`peek`, a link's card): looking at it wakes nothing. Neither of the helper's says so: the
  /// display's view must not wake the display.
  readonly peek?: boolean;
  /// What it can send, the one it would rather first; none: H.264 alone.
  readonly codecs?: readonly Codec[];
  /// Fails (with a message for the person) when it cannot be seen now: no permission to capture, no display.
  open(options: ViewOptions): Promise<ScreenView>;
  /// A device's: what a machine calls it (an AVD's name), what a person is shown and its size now, in its pixels.
  readonly name?: string;
  /** Hardware model, independent of the user-assigned instance name. */
  readonly model?: string;
  /// A device's running instance: its id names a place (an emulator's console port), which another device may take
  /// once this one goes. What drives or closes a device names the instance it picked, and is refused for another.
  readonly instance?: string;
  /// Re-read the device boot before a debug request. False means the listed boot has ended.
  current?(): Promise<boolean>;
  title?(): string;
  size?(): { width: number; height: number };
  /// A device's screen, the panels a client draws its body by.
  readonly panels?: readonly Panel[];
  /// A simulator's case and buttons as Xcode has them, each panel's (sim-chrome.ts); none: as `panels` says.
  readonly chrome?: readonly ChromeSource[];
  /// The poses a foldable takes.
  poseNames?(): DevicePose[];
  /// Closes it for good (an emulator); none: it is not closed from a person's app.
  discard?(): Promise<void>;
  /// A real phone, a person's.
  readonly phone?: boolean;
  /// What an agent's lease on it says while it lasts; null or absent: none.
  readonly agent?: string | null;
  /// Hears an agent's lease on it start and end, at once with whether one lasts now, and where the agent's finger is as
  /// it acts (`AgentSaid`); until the returned function. None: no agent leases it.
  watchAgent?(heard: (said: AgentSaid) => void): () => void;
  /// A person's view that drives it opened: given the function that says it closed (agents wait meanwhile).
  hold?(): () => void;
  /// The clipboard types its views carry both ways while a person drives (`setClipboard`, `watchClipboard`); none: no
  /// clipboard (still.fail's `clipboard()`).
  clipboard?(): ClipType[];
  /// A device's running app's logs (app-logs.ts): a simulator's, an Android device's; none: a computer's screen.
  readonly logs?: AppLogs;
  /// What debugs an app on it (sim-debug.ts, android-debug.ts): a simulator's, an emulator's; none: not this one.
  readonly debug?: DeviceDebug;
}

export type DeviceDebugAction = "restart" | "screenshot" | "record" | "install" | "appearance";
export type DeviceAppearance = "light" | "dark";
/// Which panel of a foldable a recording is of.
export type DevicePanelName = "inner" | "cover";

/// What a person debugging an app can do of the device, the mesh's `/screens/<id>/debug/<action>` (mesh/screens.ts).
export interface DeviceDebug {
  /// What this device can do: a client shows no more.
  readonly actions: readonly DeviceDebugAction[];
  /// The ends of the files `install` takes.
  readonly installTypes: readonly string[];
  state(): Promise<{ recording: boolean; appearance?: DeviceAppearance }>;
  restart(): Promise<{ app: string; name: string } | null>;
  screenshot(): Promise<Buffer>;
  recordStart(panel: DevicePanelName | null): Promise<void>;
  recordStop(): Promise<import("./recording-files.ts").RecordedMovie | null>;
  setAppearance(value: DeviceAppearance): Promise<void>;
  /// Where a file to install goes up to: `install` takes none from elsewhere.
  installFolder(): string;
  install(path: string): Promise<{ app?: string } | null>;
  close(): void;
}

/// The sources a part adds and takes away (the emulators, as adb has them).
export interface Screens {
  add(source: ScreenSource): () => void;
  list(): ScreenSource[];
  get(id: string): ScreenSource | undefined;
  /// Called with the list each time a source comes or goes (or its size changes).
  watch(listener: (sources: ScreenSource[]) => void): () => void;
}

export function makeScreens(): Screens & { changed(): void } {
  const sources = new Map<string, ScreenSource>();
  const listeners = new Set<(sources: ScreenSource[]) => void>();
  const changed = () => {
    const all = [...sources.values()];
    for (const listener of listeners) listener(all);
  };
  return {
    add(source) {
      sources.set(source.id, source);
      changed();
      return () => {
        if (sources.get(source.id) === source) {
          sources.delete(source.id);
          changed();
        }
      };
    },
    list: () => [...sources.values()],
    get: (id) => sources.get(id),
    watch(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    changed,
  };
}
