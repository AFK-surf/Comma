import { afterAll, expect, it } from "vitest";

// The test clock fakes the page's timers while a test runs and gives the page its own back after it, so work a
// test leaves behind (an unmount after it, a closing animation) still finds them.
const pageTimers = [
  "setTimeout",
  "setInterval",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;

it("runs a test on the fake timers", () => {
  for (const name of pageTimers) expect(typeof window[name], name).toBe("function");
});

it("runs the next test on them too", () => {
  for (const name of pageTimers) expect(typeof window[name], name).toBe("function");
});

afterAll(() => {
  for (const name of pageTimers) expect(typeof window[name], name).toBe("function");
});
