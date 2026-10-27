// Main's clock in an Electron e2e that moves time itself (`COMMA_ELECTRON_E2E_TEST_CLOCK`, never a release's): it
// stands still, and `advanceTestClocks` moves it together with the core's test clock, so Main's and the core's
// timers fall due in one order whatever the machine's speed.
import { settle } from "@comma/core-kernel/testing";
import type { MainClock } from "./clock";
import type { CoreClockPosition } from "./modules/core";

/** Where an e2e's clocks start (the core's TestTime zero), so a run never depends on when it ran. */
export const TEST_CLOCK_START = Date.UTC(2026, 0, 1);

/** A move that keeps finding work due at the same instant stops after this many stops. */
const MAX_STOPS = 10_000;

interface Timer {
  due: number;
  order: number;
  run: () => void;
}

export class ManualMainClock implements MainClock {
  #now: number;
  #timers: Timer[] = [];
  #order = 0;

  constructor(start = TEST_CLOCK_START) {
    this.#now = start;
  }

  now(): number {
    return this.#now;
  }

  setTimer(ms: number, run: () => void): () => void {
    const timer: Timer = {
      due: this.#now + Math.max(0, ms),
      order: ++this.#order,
      run,
    };
    const timers = this.#timers;
    let at = timers.length;
    while (at > 0 && timers[at - 1]!.due > timer.due) at--;
    timers.splice(at, 0, timer);
    return () => {
      const index = timers.indexOf(timer);
      if (index >= 0) timers.splice(index, 1);
    };
  }

  /** When the earliest timer falls due; undefined when none waits. */
  nextDue(): number | undefined {
    return this.#timers[0]?.due;
  }

  /** Moves to `time`, stopping at each timer due on the way: it runs, and what it started settles, before the next. */
  async advanceTo(time: number): Promise<void> {
    for (;;) {
      const next = this.#timers[0];
      if (!next || next.due > time) break;
      this.#timers.shift();
      this.#now = Math.max(this.#now, next.due);
      next.run();
      await settle();
    }
    this.#now = Math.max(this.#now, time);
    await settle();
  }
}

/**
 * Lets `ms` pass on Main's clock and the core's together: each stop is the earliest timer due on either, both clocks
 * reach it, and what fell due settles on both before the next. `core` moves the core's clock by an amount and says
 * where it is, or undefined while no core runs (it restarts on Main's clock after its process exits, from Main's time).
 */
export async function advanceTestClocks(
  main: ManualMainClock,
  core: (ms: number) => Promise<CoreClockPosition | undefined>,
  ms: number
): Promise<void> {
  const target = main.now() + ms;
  let position = await core(0);
  const dueBy = (time: number) =>
    (main.nextDue() ?? Infinity) <= time || (position?.nextDue ?? Infinity) <= time;
  for (let stops = 0; stops < MAX_STOPS; stops++) {
    const next = Math.min(
      target,
      main.nextDue() ?? Infinity,
      position?.nextDue ?? Infinity
    );
    // Main reaches the stop first (its timers due there run), so what the core's timers then ask of Main happens at
    // the stop's time; at a tie Main's timers run before the core's.
    await main.advanceTo(next);
    if (position) {
      position = await core(Math.max(0, next - position.now));
      // What the core asked of Main runs, and what it set due now, before the next stop.
      await main.advanceTo(next);
    }
    // A core that started on the way (Main restarted it) reads Main's time from its start.
    position = await core(0);
    await settle();
    if (next >= target && !dueBy(target)) return;
  }
  throw new Error(`The test clocks kept finding work due after ${MAX_STOPS} stops.`);
}
