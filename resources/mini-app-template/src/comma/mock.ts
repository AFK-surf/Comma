// Copied from Comma's clients/packages/miniapp-sdk. Do not edit: Comma updates this file.
/// <reference lib="dom" />
/**
 * A local stand-in for Comma: `window.comma` with in-memory stores, for
 * development outside Comma (`npm run dev`) and for headless tests.
 *
 * It runs the same SDK code as the Comma runtime (./frame.ts) over an
 * in-process host, so arguments and results are copied as they are on the
 * real port. The app template keeps a copy of this file.
 */
import { createFrameComma } from "./frame";
import {
  CommaError,
  miniAppCapabilities,
  miniAppCapabilityOps,
  miniAppOpRequirement,
  type Comma,
  type MiniAppCalendarEvent,
  type MiniAppChatMessage,
  type MiniAppDecisionRequest,
  type MiniAppDecisionResult,
  type MiniAppSearchResult,
  type MiniAppIdentity,
  type MiniAppLocation,
  type MiniAppAudioInput,
  type MiniAppMidiInput,
  type MiniAppMidiMessage,
  type MiniAppPhoto,
  type MiniAppPickedFile,
  type MiniAppShareArgs,
  type MiniAppStorageScope,
  type MiniAppStoredItem,
  type MiniAppTheme,
  type MiniAppViewer,
} from "./sdk";

export interface MockCommaOptions {
  app?: MiniAppIdentity;
  viewer?: MiniAppViewer;
  theme?: MiniAppTheme;
  tokens?: Record<string, string>;
  locale?: string;
  timeZone?: string;
  /** Capabilities of the manifest. Default: all. */
  capabilities?: string[];
  /** Granted capabilities. Default: all of `capabilities`. */
  grants?: string[];
  /** Storage scopes of the manifest. Default: all. */
  storage?: MiniAppStorageScope[];
  /** Answers `comma.ai.chat`. Default: echoes the last user message. */
  aiChat?: (messages: MiniAppChatMessage[]) => string | Promise<string>;
  /** Answers `comma.ai.decide`. Without a handler the call fails with `unavailable`. */
  aiDecide?: (
    request: MiniAppDecisionRequest
  ) => MiniAppDecisionResult | Promise<MiniAppDecisionResult>;
  /** Answers `comma.web.search`. Default: no results. */
  webSearch?: (query: string) => MiniAppSearchResult[] | Promise<MiniAppSearchResult[]>;
  /** Answers `comma.tasks.propose`: whether the user confirmed. Default: true. */
  confirmTask?: (text: string) => boolean | Promise<boolean>;
  /** Answers `comma.open`: whether the user confirmed. Default: true. */
  confirmLink?: (url: string) => boolean | Promise<boolean>;
  /** Answers `comma.files.pick`. Default: no files. */
  pickFiles?: (options: {
    accept?: string[];
    multiple?: boolean;
  }) => MiniAppPickedFile[] | Promise<MiniAppPickedFile[]>;
  /** Answers `comma.calendar.events`. Default: no events. */
  calendarEvents?: (range: {
    from: string;
    to: string;
  }) => MiniAppCalendarEvent[] | Promise<MiniAppCalendarEvent[]>;
  /**
   * The app's backend, such as the `fetch` of `worker/index.ts` with a mock
   * `env`. Default: none (`comma.backend.fetch` fails with `unsupported`).
   */
  backend?: (request: Request) => Response | Promise<Response>;
  /** Answers `comma.camera.capture`. Default: the viewer closes the sheet (null). */
  capturePhoto?: (options: {
    facing?: "user" | "environment";
  }) => MiniAppPhoto | null | Promise<MiniAppPhoto | null>;
  /** Answers `comma.location.current`. Default: fails with `unavailable`. */
  location?: () => MiniAppLocation | Promise<MiniAppLocation>;
  /** The text `comma.clipboard.read` returns. Default: the last text the app wrote, or "". */
  clipboardText?: string;
  /** Answers `comma.share`: whether the viewer shared. Default: true. */
  confirmShare?: (content: MiniAppShareArgs) => boolean | Promise<boolean>;
  /** The sample rate of `comma.microphone.start`. Default: 48000. */
  sampleRate?: number;
  /** The audio inputs of `comma.microphone.devices`; the first is the default. Default: one "Microphone". */
  audioInputs?: MiniAppAudioInput[];
  /** The inputs of `comma.midi.start`. Default: none. */
  midiInputs?: MiniAppMidiInput[];
  /** URLs for `comma.asset(path)`. Default: the path itself. */
  assets?: Record<string, string>;
}

export interface MockCall {
  op: string;
  args: unknown;
}

export interface MockComma extends Comma {
  /** What the app asked for, in order, and the effects that would reach Comma. */
  readonly mock: {
    calls: MockCall[];
    drafts: string[];
    notifications: { title: string; body: string }[];
    clipboard: string[];
    tasks: string[];
    links: string[];
    shares: MiniAppShareArgs[];
    haptics: number[][];
    /** Whether the app keeps the screen on, and shows full screen. */
    screen: { awake: boolean; fullscreen: boolean };
    /** Sends samples to the open microphone streams. */
    microphone(samples: Float32Array): void;
    /** Sends the full input channel set to multichannel streams, applying their channel selection. */
    microphoneChannels(samples: Float32Array[]): void;
    /**
     * Connects or removes audio inputs: `comma.microphone.watch` listeners get the new list, and a microphone
     * stream of a removed input ends with `ended`.
     */
    audioInputs(inputs: MiniAppAudioInput[]): void;
    /** Sends a message to the open MIDI streams. */
    midi(message: MiniAppMidiMessage): void;
    /** Stored values by scope, then key. */
    stores: Record<
      MiniAppStorageScope,
      Map<string, { value: unknown; version: number }>
    >;
    drive: Map<string, { data: ArrayBuffer; mime: string }>;
    setTheme(theme: MiniAppTheme, tokens?: Record<string, string>): void;
    setGrants(grants: string[]): void;
  };
}

const keyPattern = /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,255}$/;
// The value limits of the real stores (design §6.4).
const valueLimit: Record<MiniAppStorageScope, number> = {
  device: 32 * 1024,
  user: 1024 * 1024,
  app: 1024 * 1024,
};
const scopeLimit: Record<MiniAppStorageScope, number> = {
  device: 1024 * 1024,
  user: 10 * 1024 * 1024,
  app: 100 * 1024 * 1024,
};

const fail = (code: CommaError["code"], message: string): never => {
  throw new CommaError(code, message);
};

const byteLength = (value: unknown) =>
  new TextEncoder().encode(JSON.stringify(value)).length;

/** A `window.comma` for local development and tests. */
export function createMockComma(options: MockCommaOptions = {}): MockComma {
  const capabilities = options.capabilities ?? [...miniAppCapabilities];
  let grants = new Set(options.grants ?? capabilities);
  const scopes = options.storage ?? ["device", "user", "app"];
  const app = options.app ?? { id: "mock-app", name: "Mock app", version: 1 };
  const viewer = options.viewer ?? {
    id: "mock-viewer",
    name: "Developer",
    avatarUrl: null,
    guest: false,
  };
  const state: MockComma["mock"] = {
    calls: [],
    drafts: [],
    notifications: [],
    clipboard: [],
    tasks: [],
    links: [],
    shares: [],
    haptics: [],
    screen: { awake: false, fullscreen: false },
    microphone: (samples) => {
      for (const [stream, input] of microphones)
        if (!input.channels) frame.streamData(stream, samples.slice());
    },
    microphoneChannels: (samples) => {
      for (const [stream, input] of microphones) {
        if (!input.channels) continue;
        if (samples.length !== input.channelCount)
          throw new Error("Provide the full input channel set to the microphone mock.");
        frame.streamData(
          stream,
          input.channels.map((channel) => samples[channel]!.slice())
        );
      }
    },
    audioInputs: (inputs) => {
      audioInputs = inputs.map((input) => ({ ...input }));
      for (const [stream, input] of microphones)
        if (!audioInputs.some((device) => device.id === input.id)) {
          microphones.delete(stream);
          frame.streamEnd(stream, "ended");
        }
      for (const stream of deviceWatches)
        frame.streamData(
          stream,
          audioInputs.map((input) => ({ ...input }))
        );
    },
    midi: (message) => {
      for (const stream of midis)
        frame.streamData(stream, { ...message, data: message.data.slice() });
    },
    stores: { device: new Map(), user: new Map(), app: new Map() },
    drive: new Map(),
    setTheme: (theme, tokens = {}) => frame.setTheme({ theme, tokens }),
    setGrants: (next) => {
      grants = new Set(next);
    },
  };

  const storage = (
    scope: MiniAppStorageScope,
    method: string,
    args: Record<string, unknown>
  ) => {
    const store = state.stores[scope];
    if (
      method !== "list" &&
      (typeof args.key !== "string" || !keyPattern.test(args.key))
    )
      fail("invalid", "Keys use letters, digits and . _ / - (at most 256).");
    const key = args.key as string;
    switch (method) {
      case "get":
        return store.get(key) ?? null;
      case "put": {
        const current = store.get(key)?.version ?? 0;
        if (args.ifVersion !== undefined && args.ifVersion !== current)
          fail("conflict", `${key} has version ${current}.`);
        const size = byteLength(args.value);
        if (args.value === undefined || size > valueLimit[scope])
          fail(
            "invalid",
            `A ${scope} value is JSON of at most ${valueLimit[scope]} bytes.`
          );
        let total = size;
        for (const [other, entry] of store)
          if (other !== key) total += byteLength(entry.value);
        if (total > scopeLimit[scope])
          fail("quota_exceeded", `The ${scope} store is full.`);
        const version = current + 1;
        store.set(key, { value: structuredClone(args.value), version });
        return { version };
      }
      case "delete":
        store.delete(key);
        return null;
      default: {
        const prefix = typeof args.prefix === "string" ? args.prefix : "";
        const after = typeof args.after === "string" ? args.after : "";
        const limit = Math.min(1000, Math.max(1, Number(args.limit ?? 100) || 100));
        const keys = [...store.keys()]
          .filter((each) => each.startsWith(prefix) && each > after)
          .toSorted();
        const items: MiniAppStoredItem[] = keys
          .slice(0, limit)
          .map((each) => ({ key: each, ...store.get(each)! }));
        return { items, hasMore: keys.length > limit };
      }
    }
  };

  let streamSerial = 0;
  /** Open microphone streams, with the ID of the input each records. */
  const microphones = new Map<
    number,
    { id: string; channelCount: number | undefined; channels: number[] | undefined }
  >();
  const deviceWatches = new Set<number>();
  let audioInputs: MiniAppAudioInput[] = (
    options.audioInputs ?? [{ id: "default", name: "Microphone" }]
  ).map((input) => ({ ...input }));
  const midis = new Set<number>();

  const drivePath = (path: unknown) => {
    if (typeof path !== "string" || path.split("/").includes(".."))
      fail("invalid", "Bad path.");
    return (path as string).replace(/^\/+/, "");
  };

  const run = async (op: string, args: Record<string, unknown>): Promise<unknown> => {
    const requirement = miniAppOpRequirement(op);
    if (!requirement) return fail("unsupported", `${op} is not an SDK operation.`);
    if (op === "web.search" && viewer.guest)
      fail("signup_required", "Sign up to search the web in apps.");
    if (
      requirement.kind === "capability" &&
      requirement.capability === "ai.chat" &&
      viewer.guest
    )
      fail("signup_required", "Sign up to use AI in apps.");
    if (requirement.kind === "capability" && !grants.has(requirement.capability))
      fail("not_granted", `${requirement.capability} is not granted.`);
    if (requirement.kind === "storage") {
      const [, , method] = op.split(".");
      return storage(requirement.scope, method!, args);
    }
    switch (op) {
      case "ai.decide":
        if (!options.aiDecide)
          return fail("unavailable", "Configure aiDecide in the local mock.");
        return options.aiDecide(args as unknown as MiniAppDecisionRequest);
      case "viewer":
        return viewer;
      case "web.search": {
        const query = args.query as string;
        if (!query.trim() || query.length > 2000)
          fail("invalid", "query must contain 1 to 2,000 characters.");
        return ((await options.webSearch?.(query.trim())) ?? []).slice(0, 5);
      }
      case "ai.chat": {
        const messages = args.messages as MiniAppChatMessage[];
        const content = options.aiChat
          ? await options.aiChat(messages)
          : `Mock reply to: ${messages.findLast((message) => message.role === "user")?.content ?? ""}`;
        return { role: "assistant", content };
      }
      case "chat.draft":
        state.drafts.push(String(args.text));
        return null;
      case "tasks.propose": {
        const created = (await options.confirmTask?.(String(args.text))) ?? true;
        if (created) state.tasks.push(String(args.text));
        return { created };
      }
      case "files.pick":
        return (await options.pickFiles?.(args)) ?? [];
      case "drive.list": {
        const folder = drivePath(args.path).replace(/\/?$/, "/").replace(/^\/$/, "");
        return [...state.drive.entries()]
          .filter(
            ([path]) =>
              path.startsWith(folder) && !path.slice(folder.length).includes("/")
          )
          .map(([path, file]) => ({
            path,
            name: path.slice(folder.length),
            kind: "file",
            size: file.data.byteLength,
            mime: file.mime,
          }));
      }
      case "drive.read": {
        const file = state.drive.get(drivePath(args.path));
        return file ?? fail("not_found", `No file ${String(args.path)}.`);
      }
      case "drive.write": {
        const data = args.data;
        state.drive.set(drivePath(args.path), {
          data:
            typeof data === "string"
              ? new TextEncoder().encode(data).buffer
              : (data as ArrayBuffer),
          mime: typeof data === "string" ? "text/plain" : "application/octet-stream",
        });
        return null;
      }
      case "drive.delete":
        state.drive.delete(drivePath(args.path));
        return null;
      case "calendar.events":
        return (
          (await options.calendarEvents?.(args as { from: string; to: string })) ?? []
        );
      case "notify":
        state.notifications.push({
          title: String(args.title),
          body: String(args.body),
        });
        return null;
      case "clipboard.write":
        state.clipboard.push(String(args.text));
        return null;
      case "clipboard.read":
        return { text: options.clipboardText ?? state.clipboard.at(-1) ?? "" };
      case "microphone.devices":
        return { devices: audioInputs.map((input) => ({ ...input })) };
      case "microphone.watch":
        deviceWatches.add(++streamSerial);
        return {
          stream: streamSerial,
          devices: audioInputs.map((input) => ({ ...input })),
        };
      case "microphone.start":
      case "microphone.startChannels": {
        const device =
          args.deviceId === undefined
            ? audioInputs[0]
            : audioInputs.find((input) => input.id === args.deviceId);
        if (!device) return fail("unavailable", "There is no microphone.");
        const channelCount =
          op === "microphone.startChannels" ? Number(args.channelCount) : undefined;
        if (
          channelCount !== undefined &&
          device.channelCount &&
          (channelCount < device.channelCount.min ||
            channelCount > device.channelCount.max)
        )
          return fail(
            "unavailable",
            "The requested input channel count is not supported."
          );
        const channels =
          channelCount === undefined
            ? undefined
            : ((args.channels as number[] | undefined) ??
              Array.from({ length: channelCount }, (_, index) => index));
        microphones.set(++streamSerial, { id: device.id, channelCount, channels });
        return {
          stream: streamSerial,
          ...(channels ? { channelCount, channels } : {}),
          sampleRate: options.sampleRate ?? 48_000,
          device: { ...device },
        };
      }
      case "microphone.stop":
        microphones.delete(Number(args.stream));
        deviceWatches.delete(Number(args.stream));
        return null;
      case "midi.start":
        midis.add(++streamSerial);
        return { stream: streamSerial, inputs: options.midiInputs ?? [] };
      case "midi.stop":
        midis.delete(Number(args.stream));
        return null;
      case "camera.capture":
        return (await options.capturePhoto?.(args)) ?? null;
      case "location.current":
        if (!options.location)
          return fail("unavailable", "Configure location in the local mock.");
        return options.location();
      case "screen.keepAwake":
        state.screen.awake = args.on === true;
        return null;
      case "screen.fullscreen":
        state.screen.fullscreen = args.on === true;
        return null;
      case "share": {
        const shared = (await options.confirmShare?.(args)) ?? true;
        if (shared) state.shares.push(args as MiniAppShareArgs);
        return { shared };
      }
      case "haptics":
        state.haptics.push(args.pattern as number[]);
        return { played: true };
      case "links.open": {
        const url = String(args.url);
        if (!url.startsWith("https://")) fail("invalid", "Only https URLs open.");
        const opened = (await options.confirmLink?.(url)) ?? true;
        if (opened) state.links.push(url);
        return { opened };
      }
      case "backend.fetch": {
        if (!options.backend) return fail("unsupported", "This mock has no backend.");
        const path = String(args.path);
        const method = String(args.method ?? "GET");
        const request = new Request(new URL(path, "https://backend.invalid/"), {
          method,
          headers: args.headers as Record<string, string>,
          ...(args.body === undefined || method === "GET" || method === "HEAD"
            ? {}
            : { body: args.body as BodyInit }),
        });
        const response = await options.backend(request);
        const type = response.headers.get("content-type");
        return {
          status: response.status,
          headers: type ? { "content-type": type } : {},
          body: await response.arrayBuffer(),
        };
      }
      default:
        return fail("unsupported", `${op} is not available in the mock.`);
    }
  };

  const frame = createFrameComma({
    init: {
      app,
      viewer: grants.has("identity.basic") ? viewer : null,
      theme: options.theme ?? "light",
      tokens: options.tokens ?? {},
      locale: options.locale ?? "en-US",
      timeZone: options.timeZone ?? "UTC",
      capabilities,
      grants: [...grants],
      storage: scopes,
      backend: Boolean(options.backend),
    },
    capabilityOps: miniAppCapabilityOps,
    assetUrl: (path) => options.assets?.[path] ?? path,
    call: async (op, args) => {
      // As on the real port: what crosses is a copy.
      const copy = structuredClone(args) as Record<string, unknown>;
      state.calls.push({ op, args: copy });
      try {
        return structuredClone(await run(op, copy));
      } catch (error) {
        // The port carries `{code, message}`, not the error object.
        const message = error instanceof Error ? error.message : String(error);
        throw Object.assign(new Error(message), {
          code: error instanceof CommaError ? error.code : "failed",
        });
      }
    },
  });
  return Object.freeze(
    Object.defineProperties(
      {},
      {
        ...Object.getOwnPropertyDescriptors(frame.comma),
        mock: { value: state, enumerable: true },
      }
    )
  ) as MockComma;
}

/** Installs `createMockComma(options)` as `window.comma` unless Comma already installed one. */
export function installMockComma(options: MockCommaOptions = {}): Comma {
  const scope = globalThis as { comma?: Comma };
  if (scope.comma) return scope.comma;
  const mock = createMockComma(options);
  Object.defineProperty(globalThis, "comma", { value: mock, configurable: true });
  return mock;
}
