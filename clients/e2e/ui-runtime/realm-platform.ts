// What a realm asks of the browser beyond timers, frames and messages, on
// the realm's schedule. Each of these answers when the machine decides (a
// lock is granted by the browser process, a file handle opens on another
// thread): leaf IO, which the realm's runtime delivers in the order it
// started, before the realm rests.

import type { TestUiRuntime } from "../../packages/ui/src/runtime/test/testing";

type Method = (this: unknown, ...args: unknown[]) => Promise<unknown>;

/** Routes the platform's asynchronous answers to `runtime`; `violation` reports what cannot be routed. */
export function routePlatform(
  runtime: TestUiRuntime,
  violation: (what: string) => void
) {
  const scope = globalThis as unknown as Record<
    string,
    { prototype: Record<string, unknown> } | undefined
  >;
  const asWork = (owner: string, names: readonly string[]) => {
    const prototype = scope[owner]?.prototype;
    if (!prototype) return;
    for (const name of names) {
      const real = prototype[name] as Method | undefined;
      if (typeof real !== "function") continue;
      prototype[name] = function (this: unknown, ...args: unknown[]) {
        return runtime.load.work(`${owner} ${name}`, () => real.apply(this, args));
      };
    }
  };
  // The origin's private file system: where a worker keeps its databases.
  asWork("StorageManager", ["getDirectory", "estimate", "persist", "persisted"]);
  asWork("FileSystemHandle", ["isSameEntry", "remove"]);
  asWork("FileSystemDirectoryHandle", [
    "getFileHandle",
    "getDirectoryHandle",
    "removeEntry",
    "resolve",
  ]);
  asWork("FileSystemFileHandle", [
    "createSyncAccessHandle",
    "getFile",
    "createWritable",
  ]);
  for (const name of ["entries", "keys", "values", Symbol.asyncIterator] as const) {
    const prototype = scope.FileSystemDirectoryHandle?.prototype as
      | Record<PropertyKey, unknown>
      | undefined;
    const real = prototype?.[name] as
      | ((this: unknown) => AsyncIterableIterator<unknown>)
      | undefined;
    if (!prototype || typeof real !== "function") continue;
    prototype[name] = function (this: unknown) {
      const iterator = real.call(this);
      const next = iterator.next.bind(iterator);
      iterator.next = () => runtime.load.work("FileSystemDirectoryHandle next", next);
      return iterator;
    };
  }
  // Keys, digests and signatures are computed on other threads.
  asWork("SubtleCrypto", [
    "digest",
    "sign",
    "verify",
    "encrypt",
    "decrypt",
    "generateKey",
    "importKey",
    "exportKey",
    "deriveBits",
    "deriveKey",
    "wrapKey",
    "unwrapKey",
  ]);
  asWork("Blob", ["arrayBuffer", "text", "bytes"]);
  asWork("OffscreenCanvas", ["convertToBlob"]);
  const bitmap = (globalThis as { createImageBitmap?: Method }).createImageBitmap;
  if (bitmap)
    (globalThis as { createImageBitmap?: Method }).createImageBitmap = (...args) =>
      runtime.load.work("createImageBitmap", () => bitmap.apply(globalThis, args));

  // A lock is granted by the browser, among every context of the origin:
  // the grant is leaf IO. The realm's callback runs on its schedule, and the
  // lock is held until what the callback returned settles.
  const locks = scope.LockManager?.prototype;
  if (locks) {
    asWork("LockManager", ["query"]);
    const request = locks.request as (
      this: unknown,
      ...args: unknown[]
    ) => Promise<unknown>;
    locks.request = function (this: unknown, name: string, ...rest: unknown[]) {
      const callback = rest.at(-1) as (lock: unknown) => unknown;
      const options = rest.slice(0, -1);
      let release!: (value: unknown) => void;
      let fail!: (error: unknown) => void;
      const held = new Promise<unknown>((resolve, reject) => {
        release = resolve;
        fail = reject;
      });
      const granted = runtime.load.work(
        `lock ${name}`,
        () =>
          new Promise<unknown>((resolve, reject) => {
            request
              .call(this, name, ...options, (lock: unknown) => {
                resolve(lock);
                return held;
              })
              // Not granted (aborted, stolen); after a grant, the callback's own failure.
              .catch(reject);
          })
      );
      return granted.then((lock) => {
        const result = Promise.resolve().then(() => callback(lock));
        result.then(release, fail);
        return result;
      });
    };
  }

  // What another context of the origin broadcasts arrives when the browser
  // delivers it. Until a world carries broadcasts, receiving one is outside
  // the schedule.
  const RealBroadcastChannel = (
    globalThis as { BroadcastChannel?: typeof BroadcastChannel }
  ).BroadcastChannel;
  if (RealBroadcastChannel) {
    (globalThis as { BroadcastChannel?: unknown }).BroadcastChannel = function (
      name: string
    ) {
      const channel = new RealBroadcastChannel(name);
      channel.addEventListener(
        "message",
        (event) => {
          event.stopImmediatePropagation();
          violation(`BroadcastChannel ${name} delivered a message outside the world`);
        },
        true
      );
      return channel;
    };
  }
}
