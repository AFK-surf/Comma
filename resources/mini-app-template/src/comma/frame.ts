// Copied from Comma's clients/packages/miniapp-sdk. Do not edit: Comma updates this file.
/// <reference lib="dom" />
import type {
  Comma,
  MiniAppErrorCode,
  MiniAppFetchInit,
  MiniAppInit,
  MiniAppStorageScope,
  MiniAppStore,
  MiniAppTheme,
  MiniAppThemeChange,
} from "./sdk";

export interface FrameCommaOptions {
  init: MiniAppInit;
  /** Sends one call to the host. Rejects with `{code, message}` when the host refuses it. */
  call(op: string, args: unknown): Promise<unknown>;
  /** The `blob:` URL of a bundle file, by its normalized path. */
  assetUrl(path: string): string | undefined;
  /** `miniAppCapabilityOps` of ./sdk. */
  capabilityOps: Record<string, readonly string[]>;
}

export interface FrameComma {
  comma: Comma;
  setTheme(change: MiniAppThemeChange): void;
}

/**
 * The in-frame `window.comma`: the SDK over the runtime's port.
 *
 * The Comma app runtime (@comma/chat-contract/mini-app-runtime) embeds this
 * function's source text in its document, so it must stay self-contained:
 * no imports at runtime, no references to anything outside its body.
 */
export function createFrameComma(options: FrameCommaOptions): FrameComma {
  // `code` is typed by the interface, not a class field: the class must stay
  // plain JavaScript for every transform it passes through (Playwright's
  // Babel rejects `declare` fields), and this function is sent as its source.
  // The constructor defines `code`, so the merge describes the object it makes.
  /* oxlint-disable typescript/no-unsafe-declaration-merging */
  interface CommaError {
    readonly code: MiniAppErrorCode;
  }
  class CommaError extends Error {
    /* oxlint-enable typescript/no-unsafe-declaration-merging */
    constructor(code: MiniAppErrorCode, message: string) {
      super(message);
      this.name = "CommaError";
      Object.defineProperty(this, "code", { value: code, enumerable: true });
    }
  }
  const errorCodes = new Set([
    "unsupported",
    "not_granted",
    "denied",
    "signup_required",
    "app_paused",
    "rate_limited",
    "invalid",
    "not_found",
    "conflict",
    "quota_exceeded",
    "failed",
    "unavailable",
  ]);
  const init = options.init;
  let theme: MiniAppTheme = init.theme === "dark" ? "dark" : "light";
  const themeListeners = new Set<(change: MiniAppThemeChange) => void>();
  const capabilities = new Set(
    Array.isArray(init.capabilities) ? init.capabilities : []
  );
  const scopes = new Set(Array.isArray(init.storage) ? init.storage : []);

  const supports = (op: string) => {
    if (typeof op !== "string") return false;
    if (op === "backend.fetch") return init.backend === true;
    const storage = /^storage\.(device|user|app)\.(get|put|delete|list)$/.exec(op);
    if (storage) return scopes.has(storage[1] as MiniAppStorageScope);
    for (const [capability, ops] of Object.entries(options.capabilityOps)) {
      if (ops.includes(op)) return capabilities.has(capability);
    }
    return false;
  };

  const invoke = async (op: string, args: unknown): Promise<unknown> => {
    if (!supports(op))
      throw new CommaError("unsupported", `This app cannot use ${op} here.`);
    try {
      return await options.call(op, args);
    } catch (error) {
      if (error instanceof CommaError) throw error;
      const raw = (error ?? {}) as { code?: unknown; message?: unknown };
      const code =
        typeof raw.code === "string" && errorCodes.has(raw.code)
          ? (raw.code as MiniAppErrorCode)
          : "failed";
      throw new CommaError(
        code,
        typeof raw.message === "string" ? raw.message : `${op} failed`
      );
    }
  };

  const requireText = (name: string, value: unknown) => {
    if (typeof value !== "string")
      throw new CommaError("invalid", `${name} must be a string.`);
    return value;
  };

  const store = (scope: MiniAppStorageScope): MiniAppStore => ({
    get: async (key) =>
      (await invoke(`storage.${scope}.get`, { key: requireText("key", key) })) as never,
    put: async (key, value, putOptions) => {
      const args: { key: string; value: unknown; ifVersion?: number } = {
        key: requireText("key", key),
        value,
      };
      if (putOptions?.ifVersion !== undefined) args.ifVersion = putOptions.ifVersion;
      return (await invoke(`storage.${scope}.put`, args)) as { version: number };
    },
    delete: async (key) => {
      await invoke(`storage.${scope}.delete`, { key: requireText("key", key) });
    },
    list: async (listOptions) => {
      const args: { prefix?: string; after?: string; limit?: number } = {};
      if (listOptions?.prefix !== undefined) args.prefix = listOptions.prefix;
      if (listOptions?.after !== undefined) args.after = listOptions.after;
      if (listOptions?.limit !== undefined) args.limit = listOptions.limit;
      return (await invoke(`storage.${scope}.list`, args)) as never;
    },
  });

  const bodyBytes = async (
    body: MiniAppFetchInit["body"],
    headers: Record<string, string>
  ): Promise<string | ArrayBuffer | undefined> => {
    if (body === undefined || body === null) return undefined;
    if (typeof body === "string") return body;
    if (body instanceof ArrayBuffer) return body;
    if (ArrayBuffer.isView(body))
      return new Uint8Array(body.buffer, body.byteOffset, body.byteLength).slice()
        .buffer;
    if (body instanceof Blob) {
      if (body.type && !headers["content-type"]) headers["content-type"] = body.type;
      return body.arrayBuffer();
    }
    if (body instanceof URLSearchParams) {
      headers["content-type"] ??= "application/x-www-form-urlencoded;charset=UTF-8";
      return body.toString();
    }
    throw new CommaError(
      "invalid",
      "Use a string, ArrayBuffer, Blob or URLSearchParams body."
    );
  };

  const iso = (value: Date | string) =>
    value instanceof Date ? value.toISOString() : requireText("date", value);

  const normalizeAsset = (path: string) =>
    requireText("path", path)
      .replace(/[?#].*$/, "")
      .replace(/^(?:\.\/|\/)+/, "");

  const comma: Comma = {
    app: Object.freeze({ ...init.app }),
    get theme() {
      return theme;
    },
    locale: init.locale,
    timeZone: init.timeZone,
    supports,
    viewer: async () => (await invoke("viewer", {})) as never,
    ai: {
      chat: async (messages) => (await invoke("ai.chat", { messages })) as never,
      decide: async (request) => (await invoke("ai.decide", request)) as never,
    },
    web: {
      search: async (query) =>
        (await invoke("web.search", { query: requireText("query", query) })) as never,
    },
    chat: {
      draft: async (text) => {
        await invoke("chat.draft", { text: requireText("text", text) });
      },
    },
    tasks: {
      propose: async (text) =>
        (await invoke("tasks.propose", { text: requireText("text", text) })) as never,
    },
    files: {
      pick: async (pickOptions) => {
        const args: { accept?: string[]; multiple?: boolean } = {};
        if (pickOptions?.accept !== undefined) args.accept = pickOptions.accept;
        if (pickOptions?.multiple !== undefined) args.multiple = pickOptions.multiple;
        return (await invoke("files.pick", args)) as never;
      },
    },
    drive: {
      list: async (path = "") =>
        (await invoke("drive.list", { path: requireText("path", path) })) as never,
      read: async (path) =>
        (await invoke("drive.read", { path: requireText("path", path) })) as never,
      write: async (path, data) => {
        await invoke("drive.write", { path: requireText("path", path), data });
      },
      delete: async (path) => {
        await invoke("drive.delete", { path: requireText("path", path) });
      },
    },
    calendar: {
      events: async (range) =>
        (await invoke("calendar.events", {
          from: iso(range.from),
          to: iso(range.to),
        })) as never,
    },
    notify: async (title, body) => {
      await invoke("notify", {
        title: requireText("title", title),
        body: requireText("body", body),
      });
    },
    clipboard: {
      write: async (text) => {
        await invoke("clipboard.write", { text: requireText("text", text) });
      },
    },
    open: async (url) =>
      (await invoke("links.open", { url: requireText("url", url) })) as never,
    backend: {
      fetch: async (path, fetchInit = {}) => {
        const headers: Record<string, string> = {};
        new Headers(fetchInit.headers).forEach((value, name) => {
          headers[name] = value;
        });
        const args: {
          path: string;
          method: string;
          headers: Record<string, string>;
          body?: string | ArrayBuffer;
        } = {
          path: requireText("path", path),
          method: (fetchInit.method ?? "GET").toUpperCase(),
          headers,
        };
        const body = await bodyBytes(fetchInit.body, headers);
        if (body !== undefined) args.body = body;
        const result = (await invoke("backend.fetch", args)) as {
          status: number;
          headers?: { "content-type"?: string };
          body?: ArrayBuffer | null;
        };
        const status =
          Number.isInteger(result.status) &&
          result.status >= 200 &&
          result.status <= 599
            ? result.status
            : 502;
        const responseHeaders: Record<string, string> = {};
        const type = result.headers?.["content-type"];
        if (typeof type === "string") responseHeaders["content-type"] = type;
        const empty = [204, 205, 304].includes(status);
        return new Response(empty ? null : (result.body ?? null), {
          status,
          headers: responseHeaders,
        });
      },
    },
    storage: { device: store("device"), user: store("user"), app: store("app") },
    asset: (path) => {
      const url = options.assetUrl(normalizeAsset(path));
      if (!url) throw new CommaError("not_found", `The bundle has no file ${path}.`);
      return url;
    },
    onTheme: (listener) => {
      themeListeners.add(listener);
      return () => {
        themeListeners.delete(listener);
      };
    },
  };
  Object.freeze(comma.ai);
  Object.freeze(comma.chat);
  Object.freeze(comma.tasks);
  Object.freeze(comma.files);
  Object.freeze(comma.drive);
  Object.freeze(comma.calendar);
  Object.freeze(comma.clipboard);
  Object.freeze(comma.backend);
  for (const scope of Object.values(comma.storage)) Object.freeze(scope);
  Object.freeze(comma.storage);
  Object.freeze(comma);

  return {
    comma,
    setTheme(change) {
      theme = change.theme === "dark" ? "dark" : "light";
      for (const listener of themeListeners) {
        try {
          listener({ theme, tokens: { ...change.tokens } });
        } catch (error) {
          // A failing listener must not stop the others.
          queueMicrotask(() => {
            throw error;
          });
        }
      }
    },
  };
}
