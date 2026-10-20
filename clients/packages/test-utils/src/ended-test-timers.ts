import { AsyncLocalStorage } from "node:async_hooks";
import { beforeEach, vi } from "vitest";

const timerSteps = [
  "useFakeTimers",
  "useRealTimers",
  "setSystemTime",
  "advanceTimersByTime",
  "advanceTimersByTimeAsync",
  "advanceTimersToNextTimer",
  "advanceTimersToNextTimerAsync",
  "advanceTimersToNextFrame",
  "runAllTimers",
  "runAllTimersAsync",
  "runOnlyPendingTimers",
  "runOnlyPendingTimersAsync",
  "runAllTicks",
  "clearAllTimers",
] as const;

type TestTimers = {
  /** Which test the running code belongs to: its abort signal, entered in its `beforeEach`. */
  owner: AsyncLocalStorage<AbortSignal>;
  /** The test that runs now. */
  current: AbortSignal | null;
};

/**
 * A test that timed out runs on: Vitest starts the next test while its
 * continuations still wait. Without this, its later steps would move, install
 * or remove the fake timers of the test that runs now, and fail tests that
 * have nothing wrong. Once another test runs, a step of the fake clock from an
 * earlier test does nothing to it: a sync step throws, an async one never
 * returns. The setup files call this once per test file.
 */
export function stopTimersOfEndedTests(): void {
  const shared = globalThis as { commaTestTimers?: TestTimers };
  let timers = shared.commaTestTimers;
  if (!timers) {
    const created: TestTimers = { owner: new AsyncLocalStorage(), current: null };
    timers = created;
    shared.commaTestTimers = created;
    const fakeTimers = vi as unknown as Record<string, (...args: unknown[]) => unknown>;
    for (const name of timerSteps) {
      const step = fakeTimers[name]!;
      fakeTimers[name] = function (this: unknown, ...args: unknown[]) {
        const owner = created.owner.getStore();
        if (owner && owner !== created.current) {
          if (name.endsWith("Async")) return new Promise<never>(() => {});
          throw new Error(
            `vi.${name} after its test ended: the next test's timers stay.`
          );
        }
        return step.apply(this, args);
      };
    }
  }
  const { owner } = timers;
  beforeEach(({ signal }) => {
    timers.current = signal;
    owner.enterWith(signal);
  });
}
