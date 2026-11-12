/// <reference lib="dom" />
/**
 * The Comma mini-app SDK: the `window.comma` API that a Comma app runs with.
 *
 * Inside Comma, the app runtime installs `window.comma` before the app's
 * scripts run. For local development and headless tests outside Comma, call
 * `installMockComma()` from `./mock` first.
 *
 * This file has no imports. The app template keeps a copy of it
 * (resources/mini-app-template/src/comma/sdk.ts).
 */

/** Capabilities an app can name in `comma-app.json`. */
export const miniAppCapabilities = [
  "identity.basic",
  "ai.chat",
  "web.search",
  "chat.draft",
  "tasks.create",
  "files.pick",
  "drive.app_folder",
  "calendar.read",
  "notifications",
  "clipboard.write",
  "links.open",
  "microphone",
  "camera",
  "location",
  "screen.wake",
  "fullscreen",
  "clipboard.read",
  "share",
  "haptics",
  "midi",
  "usb",
  "bluetooth",
] as const;
export type MiniAppCapability = (typeof miniAppCapabilities)[number];

/** The SDK operations of each capability. */
export const miniAppCapabilityOps: Record<MiniAppCapability, readonly string[]> = {
  "identity.basic": ["viewer"],
  "ai.chat": ["ai.chat", "ai.decide"],
  "web.search": ["web.search"],
  "chat.draft": ["chat.draft"],
  "tasks.create": ["tasks.propose"],
  "files.pick": ["files.pick"],
  "drive.app_folder": ["drive.list", "drive.read", "drive.write", "drive.delete"],
  "calendar.read": ["calendar.events"],
  notifications: ["notify"],
  "clipboard.write": ["clipboard.write"],
  "links.open": ["links.open"],
  microphone: [
    "microphone.devices",
    "microphone.watch",
    "microphone.start",
    "microphone.startChannels",
    "microphone.stop",
  ],
  camera: ["camera.capture"],
  location: ["location.current"],
  "screen.wake": ["screen.keepAwake"],
  fullscreen: ["screen.fullscreen"],
  "clipboard.read": ["clipboard.read"],
  share: ["share"],
  haptics: ["haptics"],
  midi: ["midi.start", "midi.stop"],
  // Native browser APIs. The iframe policy and browser device chooser control access.
  usb: [],
  bluetooth: [],
};

export const miniAppStorageScopes = ["device", "user", "app"] as const;
export type MiniAppStorageScope = (typeof miniAppStorageScopes)[number];
export const miniAppStorageMethods = ["get", "put", "delete", "list"] as const;
export type MiniAppStorageMethod = (typeof miniAppStorageMethods)[number];

export type MiniAppOp =
  | "viewer"
  | "ai.chat"
  | "ai.decide"
  | "web.search"
  | "chat.draft"
  | "tasks.propose"
  | "files.pick"
  | "drive.list"
  | "drive.read"
  | "drive.write"
  | "drive.delete"
  | "calendar.events"
  | "notify"
  | "clipboard.write"
  | "links.open"
  | "microphone.devices"
  | "microphone.watch"
  | "microphone.start"
  | "microphone.stop"
  | "camera.capture"
  | "location.current"
  | "screen.keepAwake"
  | "screen.fullscreen"
  | "clipboard.read"
  | "share"
  | "haptics"
  | "midi.start"
  | "midi.stop"
  | "backend.fetch"
  | `storage.${MiniAppStorageScope}.${MiniAppStorageMethod}`;

/** What an operation needs before the host runs it. */
export type MiniAppOpRequirement =
  | { kind: "capability"; capability: MiniAppCapability }
  | { kind: "storage"; scope: MiniAppStorageScope }
  | { kind: "backend" };

/** The requirement of `op`, or undefined when `op` is not an SDK operation. */
export function miniAppOpRequirement(op: string): MiniAppOpRequirement | undefined {
  if (op === "backend.fetch") return { kind: "backend" };
  const storage = /^storage\.(device|user|app)\.(get|put|delete|list)$/.exec(op);
  if (storage) return { kind: "storage", scope: storage[1] as MiniAppStorageScope };
  for (const capability of miniAppCapabilities) {
    if (miniAppCapabilityOps[capability].includes(op))
      return { kind: "capability", capability };
  }
  return undefined;
}

export type MiniAppErrorCode =
  | "unsupported"
  | "not_granted"
  | "denied"
  | "signup_required"
  | "app_paused"
  | "rate_limited"
  | "invalid"
  | "not_found"
  | "conflict"
  | "quota_exceeded"
  | "failed"
  | "unavailable";

export type MiniAppTheme = "light" | "dark";

export interface MiniAppIdentity {
  id: string;
  name: string;
  version: number;
}

export interface MiniAppViewer {
  /** The pairwise viewer ID: stable for one user and one app, different per app. */
  id: string;
  name: string;
  avatarUrl: string | null;
  guest: boolean;
}

/** What the host sends the runtime at start (`comma-app:init`). */
export interface MiniAppInit {
  app: MiniAppIdentity;
  /** Null unless `identity.basic` is granted. */
  viewer: MiniAppViewer | null;
  theme: MiniAppTheme;
  /**
   * Comma's design system tokens as CSS custom properties, set on `<html>`, resolved for the current theme.
   * Colors: `--comma-background`, `--comma-surface`, `--comma-surface-strong`, `--comma-foreground`, `--comma-muted`,
   * `--comma-subtle`, `--comma-faint`, `--comma-border`, `--comma-border-subtle`, `--comma-primary`,
   * `--comma-primary-foreground`, `--comma-accent`, `--comma-danger`, `--comma-success`, `--comma-warning`.
   * Radius: `--comma-radius-{sm,md,lg,xl,2xl}`. Type: `--comma-font`, `--comma-text-{xs,sm,md,lg,xl,2xl}` and each
   * `--comma-text-<size>-leading`. Shadows: `--comma-shadow-{xs,sm,md,lg}`.
   */
  tokens: Record<string, string>;
  locale: string;
  timeZone: string;
  /** Manifest capabilities that this platform supports. */
  capabilities: string[];
  /** Capabilities granted now. */
  grants: string[];
  storage: MiniAppStorageScope[];
  /** Whether this Version has a backend for `backend.fetch`. */
  backend: boolean;
}

export interface MiniAppFile {
  /** A path relative to the bundle root, such as `index.html` or `assets/logo.png`. */
  path: string;
  mime: string;
  data: ArrayBuffer;
}

// --- Window messages (host <-> runtime frame) ---------------------------------

export type MiniAppHelloMessage = { type: "comma-app:hello" };
export type MiniAppReadyMessage = { type: "comma-app:ready" };
/** Sent with the transfer list `[port]`. */
export type MiniAppInitMessage = { type: "comma-app:init"; init: MiniAppInit };

// --- Port messages --------------------------------------------------------------

export type MiniAppResultMessage =
  | { type: "result"; id: number; ok: true; value: unknown }
  | {
      type: "result";
      id: number;
      ok: false;
      error: { code: MiniAppErrorCode; message: string };
    };

/** Host -> frame, over the port. */
export type MiniAppHostPortMessage =
  | { type: "files"; files: MiniAppFile[] }
  | MiniAppResultMessage
  | { type: "theme"; theme: MiniAppTheme; tokens: Record<string, string> }
  | { type: "grants"; grants: string[] }
  | { type: "stop"; reason: string }
  | { type: "ping"; n: number }
  | MiniAppStreamMessage;

/**
 * Host -> frame, over the port: data of a stream that `microphone.start`, `microphone.watch` or `midi.start`
 * opened, or its end. `stream` is the ID that the start call returned.
 */
export type MiniAppStreamMessage =
  | {
      type: "stream";
      stream: number;
      data: Float32Array | Float32Array[] | MiniAppAudioInput[] | MiniAppMidiMessage;
    }
  | { type: "stream-end"; stream: number; reason: string };

/** Frame -> host, over the port. */
export type MiniAppFramePortMessage =
  | { type: "started" }
  | { type: "error"; reason: string }
  | { type: "call"; id: number; op: string; args: unknown }
  | { type: "pong"; n: number };

// --- Operation arguments and values ---------------------------------------------

export interface MiniAppChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export type MiniAppDecisionQuestion =
  | { type: "choice"; instructions: string; criteria: Record<string, string> }
  | { type: "noul"; instructions: string; criteria?: { true: string; false: string } }
  | { type: "score"; instructions: string; criteria: string[] };

/** One to eight independent questions, with at most 12 KiB of JSON in total. */
export interface MiniAppDecisionRequest {
  state: string | Record<string, unknown> | unknown[];
  questions: Record<string, MiniAppDecisionQuestion>;
}

export type MiniAppDecisionAnswer =
  | { type: "noul"; probability_bp: number }
  | {
      type: "choice";
      choice: string;
      probabilities_bp: Record<string, number>;
      confidence_bp: number;
    }
  | {
      type: "score";
      score_milli: number;
      probabilities_bp: Record<string, number>;
      confidence_bp: number;
    };

export interface MiniAppDecisionResult {
  model: string;
  /** Probabilities use 0 to 10,000. Scores use 1,000 units per level, starting at zero. */
  answers: Record<string, MiniAppDecisionAnswer>;
}

export interface MiniAppSearchResult {
  title: string;
  url: string;
  text: string;
}

export interface MiniAppPickedFile {
  name: string;
  mime: string;
  data: ArrayBuffer;
}

/** One entry of a folder inside the app's Drive folder `Apps/<app name>/`. */
export interface MiniAppDriveEntry {
  name: string;
  kind: "file" | "folder";
  size: number | null;
  updatedAt: string | null;
}

export interface MiniAppCalendarEvent {
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  location?: string;
}

export interface MiniAppStoredValue<T = unknown> {
  value: T;
  version: number;
}

export interface MiniAppStoredItem<T = unknown> extends MiniAppStoredValue<T> {
  key: string;
}

export interface MiniAppBackendFetchArgs {
  path: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string | ArrayBuffer;
}

export interface MiniAppBackendFetchValue {
  status: number;
  headers: { "content-type"?: string };
  body: ArrayBuffer;
}

/** One photo that the viewer took with the host's camera sheet. */
export interface MiniAppPhoto {
  mime: string;
  width: number;
  height: number;
  data: ArrayBuffer;
}

export interface MiniAppLocation {
  latitude: number;
  longitude: number;
  /** Meters, at the 95% confidence level. */
  accuracy: number;
  /** ISO time of the position fix. */
  at: string;
}

export interface MiniAppShareArgs {
  title?: string;
  text?: string;
  /** An https URL. */
  url?: string;
}

/** `vibrate`: milliseconds, alternating on and off, at most 10 entries and 5 seconds in total. */
export interface MiniAppHapticsArgs {
  pattern: number[];
}

/** An audio input device. `id` is stable for this app on this device until the viewer clears site data. */
export interface MiniAppAudioInput {
  id: string;
  name: string;
  /** Browser-reported ranges, absent when unavailable. Not physical port names or a guarantee that every combination works. */
  channelCount?: { min: number; max: number };
  sampleRate?: { min: number; max: number };
}

export interface MiniAppMicrophoneChannelsOptions {
  deviceId?: string;
  /** Exact input channel count, 1 to 32 (Web Audio's limit). Unsupported counts fail instead of mixing down. */
  channelCount: number;
  /** Zero-based input channel indices, in delivery order. Default: all channels. No duplicates. */
  channels?: number[];
}

export interface MiniAppMicrophoneChannels {
  sampleRate: number;
  device: MiniAppAudioInput;
  channelCount: number;
  channels: number[];
}

export interface MiniAppMidiInput {
  id: string;
  name: string;
}

/** One MIDI message from an input device. System exclusive messages are not sent. */
export interface MiniAppMidiMessage {
  input: string;
  data: Uint8Array;
  /** Milliseconds, from the host's `performance.now()` clock. */
  time: number;
}

/** Each operation's arguments and value, as they cross the port. */
export interface MiniAppOpTable {
  viewer: { args: Record<string, never>; value: MiniAppViewer };
  "ai.chat": {
    args: { messages: MiniAppChatMessage[] };
    value: { role: "assistant"; content: string };
  };
  "ai.decide": { args: MiniAppDecisionRequest; value: MiniAppDecisionResult };
  "web.search": { args: { query: string }; value: MiniAppSearchResult[] };
  "chat.draft": { args: { text: string }; value: null };
  "tasks.propose": { args: { text: string }; value: { created: boolean } };
  "files.pick": {
    args: { accept?: string[]; multiple?: boolean };
    value: MiniAppPickedFile[];
  };
  "drive.list": { args: { path: string }; value: MiniAppDriveEntry[] };
  "drive.read": { args: { path: string }; value: { data: ArrayBuffer; mime: string } };
  "drive.write": { args: { path: string; data: ArrayBuffer | string }; value: null };
  "drive.delete": { args: { path: string }; value: null };
  "calendar.events": {
    args: { from: string; to: string };
    value: MiniAppCalendarEvent[];
  };
  notify: { args: { title: string; body: string }; value: null };
  "clipboard.write": { args: { text: string }; value: null };
  "links.open": { args: { url: string }; value: { opened: boolean } };
  "microphone.devices": {
    args: Record<string, never>;
    value: { devices: MiniAppAudioInput[] };
  };
  "microphone.watch": {
    args: Record<string, never>;
    value: { stream: number; devices: MiniAppAudioInput[] };
  };
  "microphone.start": {
    args: { deviceId?: string };
    value: { stream: number; sampleRate: number; device: MiniAppAudioInput };
  };
  "microphone.startChannels": {
    args: MiniAppMicrophoneChannelsOptions;
    value: MiniAppMicrophoneChannels & { stream: number };
  };
  "microphone.stop": { args: { stream: number }; value: null };
  "camera.capture": {
    args: { facing?: "user" | "environment" };
    value: MiniAppPhoto | null;
  };
  "location.current": { args: Record<string, never>; value: MiniAppLocation };
  "screen.keepAwake": { args: { on: boolean }; value: null };
  "screen.fullscreen": { args: { on: boolean }; value: null };
  "clipboard.read": { args: Record<string, never>; value: { text: string } };
  share: { args: MiniAppShareArgs; value: { shared: boolean } };
  haptics: { args: MiniAppHapticsArgs; value: { played: boolean } };
  "midi.start": {
    args: Record<string, never>;
    value: { stream: number; inputs: MiniAppMidiInput[] };
  };
  "midi.stop": { args: { stream: number }; value: null };
  "backend.fetch": { args: MiniAppBackendFetchArgs; value: MiniAppBackendFetchValue };
}
export type MiniAppStorageOpTable = {
  [S in MiniAppStorageScope as `storage.${S}.get`]: {
    args: { key: string };
    value: MiniAppStoredValue | null;
  };
} & {
  [S in MiniAppStorageScope as `storage.${S}.put`]: {
    args: { key: string; value: unknown; ifVersion?: number };
    value: { version: number };
  };
} & {
  [S in MiniAppStorageScope as `storage.${S}.delete`]: {
    args: { key: string };
    value: null;
  };
} & {
  [S in MiniAppStorageScope as `storage.${S}.list`]: {
    args: { prefix?: string; after?: string; limit?: number };
    value: { items: MiniAppStoredItem[]; hasMore: boolean };
  };
};

// --- The app-facing API -----------------------------------------------------------

export interface MiniAppStore {
  /** The value of `key`, or null when it has none. */
  get<T = unknown>(key: string): Promise<MiniAppStoredValue<T> | null>;
  /**
   * Stores `value` (JSON). With `ifVersion`, the write fails with `conflict`
   * when the stored version differs. Use `ifVersion: 0` to create only.
   */
  put(
    key: string,
    value: unknown,
    options?: { ifVersion?: number }
  ): Promise<{ version: number }>;
  delete(key: string): Promise<void>;
  list<T = unknown>(options?: {
    prefix?: string;
    after?: string;
    limit?: number;
  }): Promise<{ items: MiniAppStoredItem<T>[]; hasMore: boolean }>;
}

export interface MiniAppThemeChange {
  theme: MiniAppTheme;
  tokens: Record<string, string>;
}

export interface Comma {
  readonly app: MiniAppIdentity;
  readonly theme: MiniAppTheme;
  readonly locale: string;
  readonly timeZone: string;
  /** True when this app can call `op` on this platform. A grant may still be needed. */
  supports(op: MiniAppOp | (string & {})): boolean;
  viewer(): Promise<MiniAppViewer>;
  /** All AI calls use the shared `ai.chat` capability and grant. */
  ai: {
    chat(
      messages: MiniAppChatMessage[]
    ): Promise<{ role: "assistant"; content: string }>;
    /** Calls Comma's decision model with only the state supplied by this app. */
    decide(request: MiniAppDecisionRequest): Promise<MiniAppDecisionResult>;
  };
  web: {
    /** Searches the web for a query of at most 2,000 characters. Returns up to five results. */
    search(query: string): Promise<MiniAppSearchResult[]>;
  };
  chat: { draft(text: string): Promise<void> };
  tasks: { propose(text: string): Promise<{ created: boolean }> };
  files: {
    pick(options?: {
      accept?: string[];
      multiple?: boolean;
    }): Promise<MiniAppPickedFile[]>;
  };
  drive: {
    list(path?: string): Promise<MiniAppDriveEntry[]>;
    read(path: string): Promise<{ data: ArrayBuffer; mime: string }>;
    write(path: string, data: ArrayBuffer | string): Promise<void>;
    delete(path: string): Promise<void>;
  };
  calendar: {
    events(range: {
      from: Date | string;
      to: Date | string;
    }): Promise<MiniAppCalendarEvent[]>;
  };
  notify(title: string, body: string): Promise<void>;
  clipboard: {
    write(text: string): Promise<void>;
    /** Reads the clipboard's text. The viewer confirms each read. */
    read(): Promise<string>;
  };
  /** Opens an https URL outside Comma after the user confirms. */
  open(url: string): Promise<{ opened: boolean }>;
  microphone: {
    /** Captures separate PCM arrays in `channels` order, at the returned sample rate. Uses the microphone grant and lifetime of `start`. */
    startChannels(
      options: MiniAppMicrophoneChannelsOptions,
      onSamples: (samples: Float32Array[]) => void,
      onEnd?: (reason: string) => void
    ): Promise<MiniAppStreamHandle & MiniAppMicrophoneChannels>;
    /** Lists the audio input devices and their available capability ranges. */
    devices(): Promise<MiniAppAudioInput[]>;
    /**
     * Calls `onChange` with the new list each time an audio input device is connected or removed, until `stop()`.
     * `devices` is the list when it starts.
     */
    watch(
      onChange: (devices: MiniAppAudioInput[]) => void,
      onEnd?: (reason: string) => void
    ): Promise<MiniAppStreamHandle & { devices: MiniAppAudioInput[] }>;
    /**
     * Starts the microphone. Comma records it and calls `onSamples` with mono PCM chunks (-1 to 1) at `sampleRate`
     * until `stop()`, the app stops, the device is removed (reason `ended`), or the viewer revokes the grant (then
     * `onEnd` gets the reason). `options.deviceId` is an `id` from `devices()`; without it, the system's default
     * input. `device` is the input that records.
     */
    start(
      onSamples: (samples: Float32Array) => void,
      onEnd?: (reason: string) => void,
      options?: { deviceId?: string }
    ): Promise<MiniAppStreamHandle & { sampleRate: number; device: MiniAppAudioInput }>;
  };
  camera: {
    /** Opens Comma's camera sheet. Resolves with the photo the viewer takes, or null when they close the sheet. */
    capture(options?: {
      facing?: "user" | "environment";
    }): Promise<MiniAppPhoto | null>;
  };
  location: { current(): Promise<MiniAppLocation> };
  screen: {
    /** Keeps the screen on while the app is visible, until `keepAwake(false)` or the app stops. */
    keepAwake(on: boolean): Promise<void>;
    /** Shows the app full screen, or leaves full screen. Call it from a click or a key press. */
    fullscreen(on: boolean): Promise<void>;
  };
  /** Opens the system share sheet. `shared` is false when the viewer cancels it. */
  share(content: MiniAppShareArgs): Promise<{ shared: boolean }>;
  /** Vibrates the device. `played` is false when the device cannot vibrate. */
  haptics(pattern: number | number[]): Promise<{ played: boolean }>;
  midi: {
    /** Listens to every MIDI input device until `stop()`. */
    start(
      onMessage: (message: MiniAppMidiMessage) => void,
      onEnd?: (reason: string) => void
    ): Promise<MiniAppStreamHandle & { inputs: MiniAppMidiInput[] }>;
  };
  backend: {
    /** Calls the app's own backend (`worker/`). `path` starts with `/`. */
    fetch(path: string, init?: MiniAppFetchInit): Promise<Response>;
  };
  storage: Record<MiniAppStorageScope, MiniAppStore>;
  /** A `blob:` URL for a file of the app bundle, such as `comma.asset("logo.png")`. */
  asset(path: string): string;
  /** Calls `listener` when the Comma theme changes. Returns an unsubscribe function. */
  onTheme(listener: (change: MiniAppThemeChange) => void): () => void;
}

export interface MiniAppStreamHandle {
  stop(): Promise<void>;
}

export interface MiniAppFetchInit {
  method?: string;
  headers?: HeadersInit;
  body?: string | ArrayBuffer | ArrayBufferView | Blob | URLSearchParams | null;
}

/**
 * The error of every failed SDK call. `instanceof CommaError` also matches
 * errors that the Comma runtime made with its own copy of the class.
 */
// `code` is typed by the interface, not a class field (see frame.ts); the
// constructor defines it, so the merge describes the object it makes.
/* oxlint-disable typescript/no-unsafe-declaration-merging */
export interface CommaError {
  readonly code: MiniAppErrorCode;
}
export class CommaError extends Error {
  /* oxlint-enable typescript/no-unsafe-declaration-merging */
  constructor(code: MiniAppErrorCode, message: string) {
    super(message);
    this.name = "CommaError";
    Object.defineProperty(this, "code", { value: code, enumerable: true });
  }
  static override [Symbol.hasInstance](value: unknown): boolean {
    return (
      value instanceof Error &&
      value.name === "CommaError" &&
      typeof (value as { code?: unknown }).code === "string"
    );
  }
}

function currentComma(): Comma {
  const installed = (globalThis as { comma?: Comma }).comma;
  if (!installed)
    throw new Error(
      "window.comma is missing. Inside Comma the runtime installs it. For local development and tests, call installMockComma() first."
    );
  return installed;
}

/** The Comma API of the running app (`window.comma`), read when used. */
export const comma: Comma = new Proxy({} as Comma, {
  get: (_target, property) => Reflect.get(currentComma(), property),
  has: (_target, property) => Reflect.has(currentComma(), property),
});
