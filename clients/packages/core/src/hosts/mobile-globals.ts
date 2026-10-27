// What the core, Effect and zod take from a JavaScript host that Hermes has not (the phone apps' engine,
// native/engine.cpp): timers on the engine's loop (`commaNative.setTimer`), queueMicrotask, TextDecoder, structuredClone
// of plain data, AbortController, URL and URLSearchParams, Blob, performance.now, crypto, console, and the few
// library methods Hermes 0.81 lacks. Each is put in only where the engine has none of its own. Imported first by
// hosts/mobile.ts, so it is in place before any other module of the bundle runs.

/** What the engine (C++) puts on the global object for the script. */
export interface MobileNative {
  /** Starts operation `id` in the app; its answer comes to `commaCore.complete`. */
  call(id: number, op: string, json: string, bytes: ArrayBuffer | undefined): void;
  /** An operation the app answers at once (JSON). */
  callSync(op: string, json: string): string;
  /** What the core says to the app's UI. */
  emit(json: string): void;
  /** The core cannot go on: the app starts another. */
  fatal(reason: string): void;
  monotonic(): number;
  random(n: number): ArrayBuffer;
  setTimer(id: number, ms: number): void;
  clearTimer(id: number): void;
  log(level: number, message: string): void;
  /** The engine carries the phones' iroh: it answers the `mesh.*` operations itself (hosts/mobile-mesh.ts). */
  mesh?: boolean;
}

// oxlint-disable-next-line typescript/no-explicit-any -- the global object, as each shim finds it
const g = globalThis as any;
const native = g.commaNative as MobileNative;

// --- Timers: the engine's loop calls `commaTimer(id)` when one is due ---------------------------------------------

const timers = new Map<number, () => void>();
let nextTimer = 1;
g.commaTimer = (id: number) => {
  const run = timers.get(id);
  if (!run) return;
  timers.delete(id);
  run();
};
g.setTimeout = (fn: (...a: unknown[]) => void, ms?: number, ...args: unknown[]) => {
  const id = nextTimer++;
  timers.set(id, () => fn(...args));
  native.setTimer(id, Math.max(0, Number(ms) || 0));
  return id;
};
g.clearTimeout = (id: number) => {
  if (timers.delete(id)) native.clearTimer(id);
};
g.setInterval = (fn: (...a: unknown[]) => void, ms?: number, ...args: unknown[]) => {
  const id = nextTimer++;
  const every = Math.max(0, Number(ms) || 0);
  const tick = () => {
    timers.set(id, tick);
    native.setTimer(id, every);
    fn(...args);
  };
  timers.set(id, tick);
  native.setTimer(id, every);
  return id;
};
g.clearInterval = g.clearTimeout;
g.setImmediate = (fn: (...a: unknown[]) => void, ...args: unknown[]) =>
  g.setTimeout(fn, 0, ...args);
g.clearImmediate = g.clearTimeout;
if (typeof g.queueMicrotask !== "function")
  g.queueMicrotask = (fn: () => void) => void Promise.resolve().then(fn);

// --- Language and library gaps ---------------------------------------------------------------------------------------

if (typeof Symbol.asyncIterator !== "symbol")
  Object.defineProperty(Symbol, "asyncIterator", {
    value: Symbol.for("Symbol.asyncIterator"),
  });
if (typeof Array.prototype.toSorted !== "function")
  // oxlint-disable-next-line no-extend-native -- the standard method this engine lacks
  Object.defineProperty(Array.prototype, "toSorted", {
    configurable: true,
    writable: true,
    value: function toSorted<T>(this: T[], compare?: (a: T, b: T) => number): T[] {
      // oxlint-disable-next-line unicorn/no-array-sort -- this is toSorted
      return [...this].sort(compare);
    },
  });

// --- Text ------------------------------------------------------------------------------------------------------------

if (typeof g.TextDecoder !== "function") {
  g.TextDecoder = class TextDecoder {
    readonly encoding = "utf-8";
    /** The bytes of a character a streamed chunk ended inside: they begin the next chunk. */
    #held: number[] = [];
    decode(
      input?: ArrayBuffer | ArrayBufferView,
      options?: { stream?: boolean }
    ): string {
      const given =
        input === undefined
          ? new Uint8Array(0)
          : input instanceof ArrayBuffer
            ? new Uint8Array(input)
            : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      let b = given;
      if (this.#held.length > 0) {
        b = new Uint8Array(this.#held.length + given.length);
        b.set(this.#held);
        b.set(given, this.#held.length);
        this.#held = [];
      }
      let end = b.length;
      if (options?.stream === true) {
        // A character's last bytes may come with the next chunk: what could still be completed is held back.
        let lead = b.length - 1;
        while (lead >= 0 && lead >= b.length - 3 && (b[lead]! & 0xc0) === 0x80) lead--;
        if (lead >= 0 && lead >= b.length - 3) {
          const first = b[lead]!;
          const need = first >= 0xf0 ? 4 : first >= 0xe0 ? 3 : first >= 0xc0 ? 2 : 1;
          if (need > b.length - lead) {
            this.#held = Array.from(b.subarray(lead));
            end = lead;
          }
        }
      }
      let out = "";
      const chunk: number[] = [];
      const flush = () => {
        out += String.fromCharCode.apply(null, chunk);
        chunk.length = 0;
      };
      for (let i = 0; i < end; ) {
        const c = b[i]!;
        let cp = 0xfffd;
        let n = 1;
        if (c < 0x80) cp = c;
        else if (c >= 0xc2 && c < 0xe0 && i + 1 < end && (b[i + 1]! & 0xc0) === 0x80) {
          cp = ((c & 31) << 6) | (b[i + 1]! & 63);
          n = 2;
        } else if (
          c >= 0xe0 &&
          c < 0xf0 &&
          i + 2 < end &&
          (b[i + 1]! & 0xc0) === 0x80 &&
          (b[i + 2]! & 0xc0) === 0x80
        ) {
          cp = ((c & 15) << 12) | ((b[i + 1]! & 63) << 6) | (b[i + 2]! & 63);
          n = 3;
          if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff)) cp = 0xfffd;
        } else if (
          c >= 0xf0 &&
          c < 0xf5 &&
          i + 3 < end &&
          (b[i + 1]! & 0xc0) === 0x80 &&
          (b[i + 2]! & 0xc0) === 0x80 &&
          (b[i + 3]! & 0xc0) === 0x80
        ) {
          cp =
            ((c & 7) << 18) |
            ((b[i + 1]! & 63) << 12) |
            ((b[i + 2]! & 63) << 6) |
            (b[i + 3]! & 63);
          n = 4;
          if (cp < 0x10000 || cp > 0x10ffff) cp = 0xfffd;
        }
        if (cp >= 0x10000) {
          cp -= 0x10000;
          chunk.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        } else chunk.push(cp);
        if (chunk.length > 8000) flush();
        i += n;
      }
      flush();
      return out;
    }
  };
}

// --- Data ------------------------------------------------------------------------------------------------------------

/** A copy of plain data (what the core clones: JSON values, bytes, Maps, Sets, Dates). */
function clone(v: unknown, seen: Map<object, unknown>): unknown {
  if (v === null || typeof v !== "object") return v;
  if (seen.has(v)) return seen.get(v);
  if (ArrayBuffer.isView(v)) {
    const copy = new (v.constructor as new (b: ArrayBuffer) => ArrayBufferView)(
      (v.buffer as ArrayBuffer).slice(v.byteOffset, v.byteOffset + v.byteLength)
    );
    seen.set(v, copy);
    return copy;
  }
  if (v instanceof ArrayBuffer) return v.slice(0);
  // A copy of a Date the caller passed (structuredClone), not a reading of the clock.
  // @effect-diagnostics-next-line globalDate:off
  if (v instanceof Date) return new Date(v.getTime());
  if (v instanceof Map) {
    const m = new Map();
    seen.set(v, m);
    for (const [k, x] of v) m.set(clone(k, seen), clone(x, seen));
    return m;
  }
  if (v instanceof Set) {
    const s = new Set();
    seen.set(v, s);
    for (const x of v) s.add(clone(x, seen));
    return s;
  }
  if (Array.isArray(v)) {
    const a: unknown[] = [];
    seen.set(v, a);
    for (const x of v) a.push(clone(x, seen));
    return a;
  }
  const o: Record<string, unknown> = {};
  seen.set(v, o);
  for (const k of Object.keys(v)) o[k] = clone((v as Record<string, unknown>)[k], seen);
  return o;
}
if (typeof g.structuredClone !== "function")
  g.structuredClone = (v: unknown) => clone(v, new Map());

/** Bytes with a media type (what the core hands its chat API for an upload, and reads back with `arrayBuffer`). */
if (typeof g.Blob !== "function") {
  g.Blob = class Blob {
    readonly type: string;
    readonly #bytes: Uint8Array;
    constructor(
      parts: (ArrayBuffer | ArrayBufferView | string | Blob)[] = [],
      options?: { type?: string }
    ) {
      const pieces = parts.map((part) => {
        if (typeof part === "string")
          return new g.TextEncoder().encode(part) as Uint8Array;
        if (part instanceof Blob) return part.#bytes;
        if (part instanceof ArrayBuffer) return new Uint8Array(part);
        return new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
      });
      const all = new Uint8Array(pieces.reduce((n, p) => n + p.length, 0));
      let at = 0;
      for (const p of pieces) {
        all.set(p, at);
        at += p.length;
      }
      this.#bytes = all;
      this.type = options?.type ?? "";
    }
    get size(): number {
      return this.#bytes.length;
    }
    arrayBuffer(): Promise<ArrayBuffer> {
      return Promise.resolve(this.#bytes.slice().buffer);
    }
    text(): Promise<string> {
      return Promise.resolve(new g.TextDecoder().decode(this.#bytes));
    }
    slice(start = 0, end = this.#bytes.length, type = ""): Blob {
      return new Blob([this.#bytes.slice(start, end)], { type });
    }
  };
}

// --- AbortController (Effect gives one to each promise it may interrupt) ---------------------------------------------

if (typeof g.AbortController !== "function") {
  class AbortSignal {
    aborted = false;
    reason: unknown = undefined;
    onabort: ((e: unknown) => void) | null = null;
    #listeners: ((e: unknown) => void)[] = [];
    addEventListener(type: string, fn: (e: unknown) => void) {
      if (type === "abort") this.#listeners.push(fn);
    }
    removeEventListener(type: string, fn: (e: unknown) => void) {
      if (type === "abort") this.#listeners = this.#listeners.filter((l) => l !== fn);
    }
    throwIfAborted() {
      if (this.aborted) throw this.reason;
    }
    abortWith(reason: unknown) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason ?? new Error("aborted");
      const e = { type: "abort", target: this };
      this.onabort?.(e);
      for (const l of this.#listeners) l(e);
    }
  }
  g.AbortSignal = AbortSignal;
  g.AbortController = class AbortController {
    readonly signal = new AbortSignal();
    abort(reason?: unknown) {
      this.signal.abortWith(reason);
    }
  };
}

// --- URL and URLSearchParams: what the core reads and writes of them --------------------------------------------------

const formEncode = (s: string) =>
  encodeURIComponent(s)
    .replace(/%20/g, "+")
    .replace(/[!'()~]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
const formDecode = (s: string) => {
  try {
    return decodeURIComponent(s.replace(/\+/g, " "));
  } catch {
    return s;
  }
};

if (typeof g.URLSearchParams !== "function") {
  g.URLSearchParams = class URLSearchParams {
    #pairs: [string, string][] = [];
    /** Told after each change (a URL keeps its `search` in step). */
    changed: (() => void) | null = null;
    constructor(
      init?: string | Record<string, string> | [string, string][] | URLSearchParams
    ) {
      if (init === undefined || init === null) return;
      if (typeof init === "string") {
        for (const part of init.replace(/^\?/, "").split("&")) {
          if (part === "") continue;
          const at = part.indexOf("=");
          this.#pairs.push(
            at < 0
              ? [formDecode(part), ""]
              : [formDecode(part.slice(0, at)), formDecode(part.slice(at + 1))]
          );
        }
      } else if (init instanceof URLSearchParams)
        this.#pairs = init.#pairs.map(([k, v]) => [k, v]);
      else if (Array.isArray(init))
        for (const [k, v] of init) this.#pairs.push([String(k), String(v)]);
      else for (const k of Object.keys(init)) this.#pairs.push([k, String(init[k])]);
    }
    get(name: string): string | null {
      return this.#pairs.find(([k]) => k === name)?.[1] ?? null;
    }
    getAll(name: string): string[] {
      return this.#pairs.filter(([k]) => k === name).map(([, v]) => v);
    }
    has(name: string): boolean {
      return this.#pairs.some(([k]) => k === name);
    }
    append(name: string, value: string): void {
      this.#pairs.push([String(name), String(value)]);
      this.changed?.();
    }
    set(name: string, value: string): void {
      const at = this.#pairs.findIndex(([k]) => k === name);
      const rest = this.#pairs.filter(([k], i) => k !== name || i === at);
      if (at < 0) rest.push([String(name), String(value)]);
      else rest[rest.findIndex(([k]) => k === name)] = [String(name), String(value)];
      this.#pairs = rest;
      this.changed?.();
    }
    delete(name: string): void {
      this.#pairs = this.#pairs.filter(([k]) => k !== name);
      this.changed?.();
    }
    forEach(fn: (value: string, key: string) => void): void {
      for (const [k, v] of this.#pairs) fn(v, k);
    }
    entries(): IterableIterator<[string, string]> {
      return this.#pairs.map(([k, v]) => [k, v] as [string, string])[Symbol.iterator]();
    }
    [Symbol.iterator](): IterableIterator<[string, string]> {
      return this.entries();
    }
    toString(): string {
      return this.#pairs.map(([k, v]) => `${formEncode(k)}=${formEncode(v)}`).join("&");
    }
  };
}

if (typeof g.URL !== "function") {
  const absolute =
    /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/(?:([^:@/]*)(?::([^@/]*))?@)?(\[[^\]]*\]|[^:/?#]*)(?::(\d*))?([^?#]*)(\?[^#]*)?(#.*)?$/;
  const defaults: Record<string, string> = {
    "http:": "80",
    "https:": "443",
    "ws:": "80",
    "wss:": "443",
  };
  g.URL = class URL {
    protocol = "";
    username = "";
    password = "";
    hostname = "";
    port = "";
    pathname = "";
    search = "";
    hash = "";
    readonly searchParams: URLSearchParams;
    constructor(input: string | URL, base?: string | URL) {
      const s = String(input);
      let m = absolute.exec(s);
      if (!m) {
        if (base === undefined || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s))
          throw new TypeError(`Invalid URL: ${s}`);
        const b = new URL(String(base));
        const path = s.startsWith("/")
          ? s
          : s.startsWith("?") || s.startsWith("#") || s === ""
            ? `${b.pathname}${s.startsWith("#") ? b.search : ""}${s}`
            : b.pathname.replace(/[^/]*$/, "") + s;
        m = absolute.exec(`${b.protocol}//${b.host}${path}`);
        if (!m) throw new TypeError(`Invalid URL: ${s}`);
      }
      this.protocol = m[1]!.toLowerCase();
      this.username = m[2] ?? "";
      this.password = m[3] ?? "";
      this.hostname = m[4]!.toLowerCase();
      this.port = m[5] === undefined || m[5] === defaults[this.protocol] ? "" : m[5];
      this.pathname = m[6] === "" ? "/" : m[6]!;
      this.search = m[7] === "?" ? "" : (m[7] ?? "");
      this.hash = m[8] === "#" ? "" : (m[8] ?? "");
      const params = new g.URLSearchParams(this.search);
      params.changed = () => {
        const text = params.toString();
        this.search = text === "" ? "" : `?${text}`;
      };
      this.searchParams = params;
    }
    get host(): string {
      return this.port === "" ? this.hostname : `${this.hostname}:${this.port}`;
    }
    get origin(): string {
      return `${this.protocol}//${this.host}`;
    }
    get href(): string {
      const auth =
        this.username !== ""
          ? `${this.username}${this.password !== "" ? `:${this.password}` : ""}@`
          : "";
      return `${this.protocol}//${auth}${this.host}${this.pathname}${this.search}${this.hash}`;
    }
    toString(): string {
      return this.href;
    }
    toJSON(): string {
      return this.href;
    }
  };
}

// --- Clocks, randomness, the console ---------------------------------------------------------------------------------

if (typeof g.performance !== "object" || typeof g.performance?.now !== "function")
  g.performance = { now: () => native.monotonic() };
if (typeof g.crypto !== "object" || typeof g.crypto?.getRandomValues !== "function") {
  const getRandomValues = <T extends ArrayBufferView>(buf: T): T => {
    const bytes = new Uint8Array(native.random(buf.byteLength));
    new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength).set(bytes);
    return buf;
  };
  g.crypto = {
    getRandomValues,
    randomUUID(): string {
      const b = getRandomValues(new Uint8Array(16));
      b[6] = (b[6]! & 0x0f) | 0x40;
      b[8] = (b[8]! & 0x3f) | 0x80;
      const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    },
  };
}
if (typeof g.console !== "object") {
  const say =
    (level: number) =>
    (...a: unknown[]) =>
      native.log(
        level,
        a
          .map((x) =>
            typeof x === "string"
              ? x
              : x instanceof Error
                ? `${x.message}\n${x.stack ?? ""}`
                : JSON.stringify(x)
          )
          .join(" ")
      );
  g.console = { log: say(1), info: say(1), debug: say(0), warn: say(2), error: say(3) };
}
