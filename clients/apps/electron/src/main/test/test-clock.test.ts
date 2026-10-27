import { describe, expect, it } from "vitest";
import type { CoreClockPosition } from "../modules/core";
import { advanceTestClocks, ManualMainClock, TEST_CLOCK_START } from "../test-clock";

/** The core's side of a move, as its test clock answers it: timers due on the way run in order. */
function fakeCore(start: number, fired: string[]) {
  let now = start;
  const timers: Array<{ due: number; name: string; run: (() => void) | undefined }> =
    [];
  return {
    at(ms: number, name: string, run?: () => void) {
      timers.push({ due: now + ms, name, run });
      timers.sort((a, b) => a.due - b.due);
    },
    move: async (ms: number): Promise<CoreClockPosition | undefined> => {
      const target = now + ms;
      while (timers[0] && timers[0].due <= target) {
        const timer = timers.shift()!;
        now = timer.due;
        fired.push(`core ${timer.name} @${now - start}`);
        timer.run?.();
      }
      now = target;
      return { now, nextDue: timers[0]?.due };
    },
  };
}

describe("Main's test clock", () => {
  it("stands still until moved, then runs each timer at its own time", async () => {
    const clock = new ManualMainClock();
    const fired: number[] = [];
    clock.setTimer(30, () => fired.push(clock.now() - TEST_CLOCK_START));
    const cancel = clock.setTimer(20, () => fired.push(-1));
    clock.setTimer(10, () => {
      fired.push(clock.now() - TEST_CLOCK_START);
      clock.setTimer(5, () => fired.push(clock.now() - TEST_CLOCK_START));
    });
    cancel();

    expect(clock.now()).toBe(TEST_CLOCK_START);
    await clock.advanceTo(TEST_CLOCK_START + 25);
    expect(fired).toEqual([10, 15]);
    expect(clock.now()).toBe(TEST_CLOCK_START + 25);
    expect(clock.nextDue()).toBe(TEST_CLOCK_START + 30);
  });

  it("moves with the core's clock: Main's and the core's timers fall due in one order", async () => {
    const main = new ManualMainClock();
    const fired: string[] = [];
    const core = fakeCore(main.now(), fired);
    const mainAt = (ms: number, name: string) =>
      main.setTimer(ms, () =>
        fired.push(`main ${name} @${main.now() - TEST_CLOCK_START}`)
      );
    core.at(50, "retry");
    mainAt(100, "timeout");
    // What the core's timer starts on Main falls due after it, on the same timeline.
    core.at(150, "renew", () => mainAt(10, "answer"));
    mainAt(200, "expiry");
    core.at(400, "later");

    await advanceTestClocks(main, core.move, 300);

    expect(fired).toEqual([
      "core retry @50",
      "main timeout @100",
      "core renew @150",
      "main answer @160",
      "main expiry @200",
    ]);
    expect(main.now()).toBe(TEST_CLOCK_START + 300);
    expect(await core.move(0)).toEqual({
      now: TEST_CLOCK_START + 300,
      nextDue: TEST_CLOCK_START + 400,
    });
  });
});
