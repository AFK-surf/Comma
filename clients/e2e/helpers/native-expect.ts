import { expect as playwrightExpect } from "@playwright/test";

const samples = { calls: 0, callbackMs: 0, retryGapMs: 0 };
process.once("exit", () => {
  console.log("E2E native poll worker " + JSON.stringify(samples));
});

// Native state changes often finish between the default 100/250/500ms probes.
// Shorter probes reduce idle assertion time without changing the deadline or
// condition. Explicit per-call intervals still take precedence.
const pollNative: typeof playwrightExpect.poll = (actual, options) => {
  let previousEnd: number | undefined;
  return playwrightExpect.poll(
    async () => {
      const started = performance.now();
      if (previousEnd !== undefined) samples.retryGapMs += started - previousEnd;
      try {
        return await actual();
      } finally {
        previousEnd = performance.now();
        samples.calls += 1;
        samples.callbackMs += previousEnd - started;
      }
    },
    {
      intervals: [20, 50, 100, 250],
      ...(typeof options === "string" ? { message: options } : options),
    }
  );
};

// Keep this policy local to the importing specs. Do not mutate Playwright's
// shared expect instance or alter locator assertion behavior.
export const expect = new Proxy(playwrightExpect, {
  get(target, property, receiver) {
    return property === "poll" ? pollNative : Reflect.get(target, property, receiver);
  },
});
