import { expect, type Page, type Worker } from "@playwright/test";
import { createRequire } from "node:module";
import { build } from "vite";
import { COALESCE_MS } from "@comma/core-kernel";

const require = createRequire(import.meta.url);
let clockBundle: Promise<string> | undefined;

function bundledClock() {
  return (clockBundle ??= build({
    configFile: false,
    logLevel: "silent",
    build: {
      write: false,
      minify: false,
      lib: {
        entry: require.resolve("@sinonjs/fake-timers"),
        name: "CommaFakeTimers",
        formats: ["iife"],
      },
    },
  }).then((result) => {
    for (const output of Array.isArray(result) ? result : [result]) {
      if (!("output" in output)) continue;
      const chunk = output.output.find((item) => item.type === "chunk");
      if (chunk?.type === "chunk") return chunk.code;
    }
    throw new Error("Could not bundle the client core's test clock");
  }));
}

/**
 * Controls the clock of the client core the page runs (its tab's Worker), not a renderer mock or a shortened
 * deadline: the core's timers are Effect's Clock, which reads `Date` and `setTimeout` there.
 */
export async function installCoreWorkerClock(
  page: Page,
  {
    timers = true,
  }: {
    /** False: only the wall clock moves (freshness checks); every timer keeps real time. */
    timers?: boolean;
  } = {}
) {
  let worker: Worker | undefined;
  await expect
    .poll(() => {
      const cores = page
        .workers()
        .filter((candidate) => candidate.url().includes("core.worker"));
      worker = cores.length === 1 ? cores[0] : undefined;
      return cores.length;
    })
    .toBe(1);
  const core = worker!;
  if (!timers) {
    await core.evaluate(`${await bundledClock()}; globalThis.__commaTestClock = CommaFakeTimers.install({
      now: Date.now(), toFake: ["Date"]
    }); undefined`);
    return {
      advance: (milliseconds: number) =>
        core.evaluate(`globalThis.__commaTestClock.tickAsync(${milliseconds})`),
      dispose: () =>
        core
          .evaluate(
            "globalThis.__commaTestClock.uninstall(); delete globalThis.__commaTestClock"
          )
          .catch(() => undefined),
    };
  }
  await core.evaluate(`${await bundledClock()};
    const realSetTimeout = globalThis.setTimeout, realClearTimeout = globalThis.clearTimeout;
    globalThis.__commaTestClock = CommaFakeTimers.install({
      now: Date.now(), toFake: ["Date", "setTimeout", "clearTimeout"], shouldClearNativeTimers: true
    });
    const fakeSetTimeout = globalThis.setTimeout, fakeClearTimeout = globalThis.clearTimeout;
    // Two delays stay real, both of them the runtime's, not the product's time: 0, Effect's scheduler yielding
    // between fibers (faked, no fiber would run until the test moved time), and ${COALESCE_MS} ms, the core's window
    // for sending changes to its UIs together (faked, no change would reach the page until the test moved time).
    // Every other timer (deadlines, backoffs, reads, the device's writes) is the test's.
    globalThis.setTimeout = (run, ms, ...args) =>
      (ms ?? 0) <= 0 || ms === ${COALESCE_MS}
        ? { real: realSetTimeout(run, ms, ...args) }
        : fakeSetTimeout(run, ms, ...args);
    globalThis.clearTimeout = (handle) =>
      handle && typeof handle === "object" && "real" in handle
        ? realClearTimeout(handle.real)
        : fakeClearTimeout(handle);
    undefined`);
  return {
    advance: (milliseconds: number) =>
      core.evaluate(`globalThis.__commaTestClock.tickAsync(${milliseconds})`),
    async dispose() {
      await core
        .evaluate(
          "globalThis.__commaTestClock.uninstall(); delete globalThis.__commaTestClock"
        )
        .catch(() => undefined);
    },
  };
}
