// Copied from Comma's clients/packages/miniapp-sdk. Do not edit: Comma updates this file.
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
  | { type: "ping"; n: number };

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
  clipboard: { write(text: string): Promise<void> };
  /** Opens an https URL outside Comma after the user confirms. */
  open(url: string): Promise<{ opened: boolean }>;
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
