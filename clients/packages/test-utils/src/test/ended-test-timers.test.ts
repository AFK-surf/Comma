import { expect, it, vi } from "vitest";

type TestTimers = {
  owner: { run<R>(signal: AbortSignal, step: () => R): R };
};
const { owner } = (globalThis as unknown as { commaTestTimers: TestTimers })
  .commaTestTimers;

it("keeps an ended test's steps off the running test's fake timers", async () => {
  vi.useFakeTimers();
  const fired: number[] = [];
  setTimeout(() => fired.push(Date.now()), 100);
  // Code of a test that timed out and ran on: it carries that test's signal.
  const ended = new AbortController().signal;

  owner.run(ended, () => {
    expect(() => vi.advanceTimersByTime(100)).toThrow(/after its test ended/);
    expect(() => vi.useRealTimers()).toThrow(/after its test ended/);
  });
  let returned = false;
  void owner
    .run(ended, () => vi.advanceTimersByTimeAsync(100))
    .then(() => {
      returned = true;
    });
  await Promise.resolve();
  expect(returned).toBe(false);
  expect(fired).toEqual([]);
  expect(vi.isFakeTimers()).toBe(true);

  // The running test's own steps move its timers.
  vi.advanceTimersByTime(100);
  expect(fired).toHaveLength(1);
});
