// Random numbers in the test's page (./child) come from one seed per test,
// derived from its file and name (./page): the test draws the same sequence
// whether it runs alone or with its file. Math.random, crypto.getRandomValues
// and crypto.randomUUID all draw from it, in the page, in the same-origin
// frames it opens, and in its workers (each from the page's seed and its order
// of creation, ./workers and ./worker-seed). A test fails when the page
// replaced one of them, or asked the browser for a key
// (crypto.subtle.generateKey).

/** A 32-bit seed for `name` (FNV-1a). */
export function seedFor(name: string) {
  let hash = 0x811c_9dc5;
  for (let index = 0; index < name.length; index += 1) {
    hash ^= name.charCodeAt(index);
    hash = Math.imul(hash, 0x0100_0193);
  }
  return hash >>> 0;
}

/** Installs the seeded sources in `view`, drawing from `seed`; returns a check that they are still in place. */
export function installSeededRandom(view: typeof globalThis, seed: number) {
  let state = seed | 0;
  // mulberry32
  const next = () => {
    state = (state + 0x6d2b_79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return (value ^ (value >>> 14)) >>> 0;
  };
  view.Math.random = () => next() / 4_294_967_296;
  const crypto = view.crypto;
  const getRandomValues = <T extends ArrayBufferView | null>(array: T): T => {
    if (!array) return array;
    const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
    for (let index = 0; index < bytes.length; index += 4) {
      const word = next();
      for (let shift = 0; shift < 4 && index + shift < bytes.length; shift += 1)
        bytes[index + shift] = (word >>> (shift * 8)) & 0xff;
    }
    return array;
  };
  Object.defineProperty(crypto, "getRandomValues", {
    configurable: true,
    value: getRandomValues,
  });
  Object.defineProperty(crypto, "randomUUID", {
    configurable: true,
    value: () => {
      const bytes = getRandomValues(new Uint8Array(16));
      bytes[6] = (bytes[6]! & 0x0f) | 0x40;
      bytes[8] = (bytes[8]! & 0x3f) | 0x80;
      const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
        ""
      );
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    },
  });
  const random = view.Math.random;
  const randomUUID = crypto.randomUUID;
  // Keys the browser generates draw on its own randomness. A context that is
  // not secure (a sandboxed frame's worker) has no crypto.subtle.
  const subtle = crypto.subtle as SubtleCrypto | undefined;
  for (const name of subtle ? (["generateKey"] as const) : [])
    Object.defineProperty(subtle, name, {
      configurable: true,
      value: () => {
        throw new Error(
          `The test page called crypto.subtle.${name}, whose randomness the test's seed does not reach.`
        );
      },
    });
  return () =>
    view.Math.random === random &&
    crypto.getRandomValues === getRandomValues &&
    crypto.randomUUID === randomUUID;
}

/** Seeds each same-origin frame the page adds, from the page's seed and the frame's order. */
export function seedNestedFrames(root: Document, seed: number) {
  let frames = 0;
  const seedFrame = (frame: HTMLIFrameElement) => {
    const order = (frames += 1);
    const install = () => {
      const view = frame.contentWindow as typeof globalThis | null;
      if (view) installSeededRandom(view, derivedSeed(seed, order));
    };
    install();
    frame.addEventListener("load", install);
  };
  new MutationObserver((records) => {
    for (const record of records)
      for (const node of record.addedNodes) {
        if (node instanceof HTMLIFrameElement) seedFrame(node);
        else if (node instanceof Element)
          for (const frame of node.querySelectorAll("iframe")) seedFrame(frame);
      }
  }).observe(root, { childList: true, subtree: true });
}

/** The seed of the `order`th worker or frame of a page seeded with `seed`. */
export const derivedSeed = (seed: number, order: number) =>
  (seed + order * 0x9e37_79b9) >>> 0;

/** The URL fragment that carries a worker's seed (./worker-seed). */
export const workerSeedParameter = "comma-random-seed";
