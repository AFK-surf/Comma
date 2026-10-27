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
  type MiniAppPickedFile,
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
