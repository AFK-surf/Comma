import { afterEach, beforeEach } from "vitest";
import { commands } from "vitest/browser";
import { frameState } from "./digest";
import { installSeededRandom, seedFor } from "./random";
import { beginRecord, endRecord, newTest, recording, testRecorded } from "./record";

// The deterministic harness of a browser test's own frame (the component
// tests that render here, not in a page of their own, ./page): random numbers
// from the test's seed, storage in memory and empty at each test, and no
// network beyond the test server. What a component would fetch, a test
// scripts (a scripted core, a fake); a request elsewhere fails the test.

class MemoryStorage implements Storage {
  #values = new Map<string, string>();
  get length() {
    return this.#values.size;
  }
  clear() {
    this.#values.clear();
  }
  getItem(key: string) {
    return this.#values.get(key) ?? null;
  }
  key(index: number) {
    return [...this.#values.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.#values.delete(key);
  }
  setItem(key: string, value: string) {
    this.#values.set(key, String(value));
  }
}

const outside = (url: string | URL) =>
  new URL(String(url), location.href).origin !== location.origin;

const refuse = (what: string, url: string | URL): never => {
  throw new Error(
    `A browser test made a real request (${what} ${String(url)}): its network is the test server alone.`
  );
};

/** Installs the frame's harness: before each test, its seed and empty storage. */
export function installTesterHarness() {
  const fetch = window.fetch.bind(window);
  window.fetch = (input, init) => {
    const url = input instanceof Request ? input.url : input;
    if (outside(url)) refuse("fetch", url);
    return fetch(input, init);
  };
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (
    this: XMLHttpRequest,
    method: string,
    url: string | URL,
    ...rest: [boolean?, string?, string?]
  ) {
    if (outside(url)) refuse(`XMLHttpRequest ${method}`, url);
    return (open as (...a: unknown[]) => void).call(this, method, url, ...rest);
  };
  const NativeWebSocket = window.WebSocket;
  window.WebSocket = class extends NativeWebSocket {
    constructor(url: string | URL, protocols?: string | string[]) {
      const target = new URL(String(url), location.href);
      if (target.host !== location.host) refuse("WebSocket", url);
      super(url, protocols);
    }
  };
  const NativeEventSource = window.EventSource;
  window.EventSource = class extends NativeEventSource {
    constructor(url: string | URL, options?: EventSourceInit) {
      if (outside(url)) refuse("EventSource", url);
      super(url, options);
    }
  };
  beforeEach(async (context) => {
    // The browser as a fresh page finds it, whatever the last test left: no
    // key or button held, no emulation, the pointer outside the frame.
    await commands.resetBrowserState({
      scale: undefined,
      media: {
        reducedMotion: "no-preference",
        colorScheme: "light",
        forcedColors: "none",
        contrast: "no-preference",
        media: "screen",
      },
    });
    await commands.mouseLeaveFrame();
    newTest();
    installSeededRandom(
      window,
      seedFor(`${context.task.file.name} > ${context.task.name}`)
    );
    for (const name of ["localStorage", "sessionStorage"] as const)
      Object.defineProperty(window, name, {
        configurable: true,
        value: new MemoryStorage(),
      });
  });
  // A test that renders in this frame records what it left there, before
  // its own cleanup runs (the browser project runs hooks in list order).
  afterEach(async (context) => {
    if (testRecorded()) return;
    const file = `clients/${context.task.file.name}`;
    await beginRecord(file, context.task.name);
    // Only while records are written (the determinism proof): CI runs once.
    if (!recording()) return;
    await endRecord(
      file,
      context.task.name,
      context.task.result?.state === "fail" ? "failed" : "passed",
      frameState()
    );
  });
}
