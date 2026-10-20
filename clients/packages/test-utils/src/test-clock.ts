import { vi } from "vitest";

import { testEpoch } from "./test-epoch";

export { testEpoch };

type SharedClock = { commaTestClock?: { installed: boolean } };

/**
 * Every jsdom test runs on one fake clock: timers, `Date`, `performance.now()`
 * and frame callbacks move only when the test moves them (`advance` and
 * `flush` in fake-clock.ts, `vi.advanceTimersByTime`, or testing-library's
 * waits, which step it), so a result never depends on machine speed.
 *
 * setup-clock.ts installs it before any other module loads. React's scheduler
 * and other libraries keep the timer functions they find when they load, so
 * the clock is never replaced or removed afterwards: `vi.useFakeTimers()` only
 * sets its time, and `vi.useRealTimers()` does nothing. Each test starts at
 * `testEpoch` with no timer pending.
 */
export function installTestClock() {
  const shared = globalThis as SharedClock;
  if (shared.commaTestClock?.installed) return;
  vi.useFakeTimers({ now: testEpoch });
  shared.commaTestClock = { installed: true };
  // Testing-library steps a fake clock while it waits when it sees `jest`.
  (globalThis as { jest?: unknown }).jest = {
    advanceTimersByTime: (ms: number) => vi.advanceTimersByTime(ms),
  };
  const fakeTimers = vi as unknown as Record<string, (...args: unknown[]) => unknown>;
  const setTime = vi.setSystemTime.bind(vi);
  fakeTimers.useFakeTimers = (config?: unknown) => {
    const now = (config as { now?: number | Date } | undefined)?.now;
    if (now !== undefined) setTime(now);
    return vi;
  };
  fakeTimers.useRealTimers = () => vi;
}

/**
 * Sets the clock back to `testEpoch`. Timers a test left stay: React's
 * scheduler keeps one pending while it has work, and drops nothing it has not
 * run, so a cleared timer would stop it for good.
 */
export function resetTestClock() {
  vi.setSystemTime(testEpoch);
}
