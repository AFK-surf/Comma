import { createHash } from "node:crypto";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { relative, resolve } from "node:path";
import { beforeEach, expect } from "vitest";

// Every unit test draws its random values from its own seed: the file and the
// test's full name. `Math.random`, Web Crypto's `getRandomValues` and
// `randomUUID`, `node:crypto`'s random bytes, fills, integers and UUIDs (with
// them uuid, nanoid and memfs's mkdtemp names) and object URLs give the same
// values in every run and in any order of the tests. Values drawn while the
// file loads come from the file's seed. Keys the platform generates
// (`generateKeyPair`, `subtle.generateKey`) and native modules keep their own
// entropy.

const require = createRequire(import.meta.url);
const repository = resolve(import.meta.dirname, "../../../..");

// xoshiro128**: four 32-bit words of state, from the seed's SHA-256. Each
// source draws from its own stream, so a library that calls `Math.random`
// once on first use, in whichever test comes first, moves no other value.
class Stream {
  private state = new Uint32Array(4);

  constructor(private readonly purpose: string) {}

  seed(text: string) {
    const digest = createHash("sha256").update(`${text}\n${this.purpose}`).digest();
    this.state = new Uint32Array(digest.buffer, digest.byteOffset, 4).slice();
  }

  next() {
    const state = this.state;
    const [a, b, c, d] = state as unknown as [number, number, number, number];
    const result = Math.imul(rotate(Math.imul(b, 5), 7), 9) >>> 0;
    state[2] = c ^ a;
    state[3] = d ^ b;
    state[1] = b ^ state[2]!;
    state[0] = a ^ state[3]!;
    state[2] ^= b << 9;
    state[3] = rotate(state[3]!, 11);
    return result;
  }

  /** In [0, 1), from 53 bits. */
  fraction() {
    return (this.next() * 2 ** 21 + (this.next() >>> 11)) / 2 ** 53;
  }

  randomize<T extends ArrayBufferView>(view: T): T {
    const bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
    for (let index = 0; index < bytes.length; index += 4) {
      let word = this.next();
      for (let byte = index; byte < Math.min(index + 4, bytes.length); byte += 1) {
        bytes[byte] = word & 0xff;
        word >>>= 8;
      }
    }
    return view;
  }

  uuid() {
    const bytes = this.randomize(new Uint8Array(16));
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
      ""
    );
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
}

const rotate = (x: number, k: number) => ((x << k) | (x >>> (32 - k))) >>> 0;

const mathRandom = new Stream("Math.random");
const bytes = new Stream("crypto bytes");
const uuids = new Stream("crypto UUIDs");
const temporaryNames = new Stream("temporary names");
const objectUrls = new Stream("object URLs");
const streams = [mathRandom, bytes, uuids, temporaryNames, objectUrls];
const seed = (text: string) => {
  for (const stream of streams) stream.seed(text);
};

/**
 * Runs `make` (memfs's mkdtemp, ./memory-tmp) with `Math.random` drawing from
 * the temporary names' own stream.
 */
export function namingTemporaryFiles<T>(make: () => T): T {
  const random = Math.random;
  Math.random = () => temporaryNames.fraction();
  try {
    return make();
  } finally {
    Math.random = random;
  }
}

// Answers a callback form later, as Node does; returns the value otherwise.
const later = (callback: unknown, value: unknown) => {
  if (typeof callback !== "function") return value;
  queueMicrotask(() =>
    (callback as (error: null, value: unknown) => void)(null, value)
  );
  return undefined;
};

const define = (target: object, name: string, value: unknown) =>
  Object.defineProperty(target, name, { configurable: true, writable: true, value });

/** Gives each test of this file its own seeded random values. */
export function seedRandomPerTest() {
  const file = relative(repository, expect.getState().testPath ?? "");
  seed(file);

  define(Math, "random", () => mathRandom.fraction());

  const webCrypto = globalThis.crypto;
  define(webCrypto, "getRandomValues", <T extends ArrayBufferView | null>(view: T) =>
    view === null ? view : bytes.randomize(view)
  );
  define(webCrypto, "randomUUID", () => uuids.uuid());

  const crypto = require("node:crypto") as Record<string, unknown>;
  define(crypto, "randomBytes", (size: number, callback?: unknown) =>
    later(callback, bytes.randomize(Buffer.alloc(size)))
  );
  define(crypto, "pseudoRandomBytes", crypto.randomBytes);
  define(
    crypto,
    "randomFillSync",
    (view: ArrayBufferView, offset = 0, size?: number) => {
      const length = size ?? view.byteLength - offset;
      bytes.randomize(new Uint8Array(view.buffer, view.byteOffset + offset, length));
      return view;
    }
  );
  define(crypto, "randomFill", (view: ArrayBufferView, ...rest: unknown[]) => {
    const callback = rest.pop();
    const [offset, size] = rest as [number?, number?];
    return later(
      callback,
      (crypto.randomFillSync as (...a: unknown[]) => unknown)(view, offset, size)
    );
  });
  define(crypto, "randomUUID", () => uuids.uuid());
  define(crypto, "randomInt", (...args: unknown[]) => {
    const callback = typeof args.at(-1) === "function" ? args.pop() : undefined;
    const [min, max] = (args.length === 1 ? [0, args[0]] : args) as [number, number];
    return later(callback, min + Math.floor(bytes.fraction() * (max - min)));
  });
  // Node names an object URL from its own entropy: the URL a test sees is
  // seeded, and the platform's functions that take one map it back.
  const real = new Map<string, string>();
  const toReal = (url: unknown) =>
    typeof url === "string" ? (real.get(url) ?? url) : url;
  const { createObjectURL, revokeObjectURL } = URL;
  define(URL, "createObjectURL", (object: Blob) => {
    const url = `blob:nodedata:${objectUrls.uuid()}`;
    real.set(url, createObjectURL.call(URL, object));
    return url;
  });
  define(URL, "revokeObjectURL", (url: string) => {
    revokeObjectURL.call(URL, toReal(url) as string);
    real.delete(url);
  });
  const buffer = require("node:buffer") as Record<string, unknown>;
  const resolveObjectURL = buffer.resolveObjectURL as (url: string) => unknown;
  define(buffer, "resolveObjectURL", (url: string) =>
    resolveObjectURL(toReal(url) as string)
  );
  const fetch = globalThis.fetch;
  if (fetch)
    define(globalThis, "fetch", (input: unknown, init?: RequestInit) =>
      fetch(toReal(input) as RequestInfo, init)
    );
  syncBuiltinESMExports();

  beforeEach((context) => {
    const names: string[] = [];
    for (
      let task: { name: string; suite?: unknown } | undefined = context.task;
      task;
    ) {
      names.unshift(task.name);
      task = task.suite as typeof task;
    }
    seed(`${file}\n${names.join("\n")}`);
  });
}
