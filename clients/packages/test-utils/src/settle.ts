import { afterEach, beforeEach, vi } from "vitest";
import { forbidRealIo } from "./io-guard";

/**
 * Moves the fake clock until `promise` settles, a little at a time, so each
 * timer the code under test sets runs at its own time; then returns what it
 * settled with. A promise still pending after `limitMs` of fake time fails.
 */
export async function settle<T>(
  promise: Promise<T>,
  { stepMs = 10, limitMs = 10_000 }: { stepMs?: number; limitMs?: number } = {}
): Promise<T> {
  const state = { settled: false };
  const done = promise.finally(() => {
    state.settled = true;
  });
  // A rejection surfaces from `done` below, not as an unhandled one meanwhile.
  done.catch(() => undefined);
  await vi.advanceTimersByTimeAsync(0);
  for (let elapsed = 0; !state.settled; elapsed += stepMs) {
    if (elapsed >= limitMs)
      throw new Error(
        `The awaited work did not settle within ${limitMs}ms of fake time.`
      );
    await vi.advanceTimersByTimeAsync(stepMs);
  }
  return done;
}

// The real setImmediate, kept before any test fakes it: a check of the fake
// clock runs once the test's own promises have all run.
const nativeSetImmediate = globalThis.setImmediate;

/**
 * Runs each test of the file on fake timers that move by themselves, to the
 * next timer, whenever the test is waiting and nothing else is left to run:
 * the code under test waits no real time, and its timers fire in their order.
 * "Nothing else left" is a turn of the real event loop with no work queued
 * (a real setImmediate). That holds only without real IO, whose callback could
 * still be on its way: the file forbids real IO (./io-guard), and fails at the
 * first.
 */
export function fakeTimersStepWhenIdle() {
  forbidRealIo();
  let running = false;
  const step = () => {
    if (!running) return;
    void vi.advanceTimersToNextTimerAsync().then(() => nativeSetImmediate(step));
  };
  beforeEach(() => {
    vi.useFakeTimers();
    running = true;
    nativeSetImmediate(step);
  });
  afterEach(() => {
    running = false;
  });
}
