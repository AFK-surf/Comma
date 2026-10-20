/**
 * The one time source of UI code (packages/app, packages/ui and the renderer
 * entry points). Presentation timing — motion, hover intent, focus after
 * paint, flash durations — reads the time and schedules work here, never on
 * `setTimeout`, `setInterval`, `requestAnimationFrame`, `Date.now()` or
 * `performance.now()` directly (`pnpm check:foundation`). Business timing
 * (polling, retries, expiry) belongs to the client core, on its Clock.
 *
 * In production the clock is the platform's. A test installs a virtual clock
 * (`createVirtualUiClock` in `./virtual`) and steps it explicitly. The real
 * clock looks the platform functions up on each call, so a page-level fake
 * (Vitest fake timers, Playwright's clock, `e2e/helpers/virtual-time.ts`)
 * also drives it.
 */
export type CancelUiTimer = () => void;

export type UiClock = {
  /** Wall-clock time in ms since the epoch (`Date.now()`). */
  now(): number;
  /** Monotonic time in ms, for durations and frame loops (`performance.now()`). */
  monotonic(): number;
  /** Runs `run` once after `ms` (`setTimeout`). */
  after(ms: number, run: () => void): CancelUiTimer;
  /** Runs `run` every `ms` (`setInterval`). */
  every(ms: number, run: () => void): CancelUiTimer;
  /**
   * Runs `run` before the next paint with the frame time (`requestAnimationFrame`), of `view` when the work is for
   * another window's document (a popover or an editor owned by another window); the virtual clock has one timeline.
   */
  frame(run: (time: number) => void, view?: Window | null): CancelUiTimer;
};

export const realUiClock: UiClock = {
  now: () => Date.now(),
  monotonic: () => performance.now(),
  after(ms, run) {
    const timer = setTimeout(run, ms);
    return () => clearTimeout(timer);
  },
  every(ms, run) {
    const timer = setInterval(run, ms);
    return () => clearInterval(timer);
  },
  frame(run, view) {
    const target = view ?? globalThis;
    const frame = target.requestAnimationFrame(run);
    return () => target.cancelAnimationFrame(frame);
  },
};

let current: UiClock = realUiClock;

/** The installed UI clock. Each call goes to the clock installed at that time. */
export const uiClock: UiClock = {
  now: () => current.now(),
  monotonic: () => current.monotonic(),
  after: (ms, run) => current.after(ms, run),
  every: (ms, run) => current.every(ms, run),
  frame: (run, view) => current.frame(run, view),
};

/**
 * Makes `clock` the UI clock. Returns a function that puts the previous clock
 * back. Work already scheduled stays on the clock that scheduled it.
 */
export function installUiClock(clock: UiClock): () => void {
  const previous = current;
  current = clock;
  return () => {
    current = previous;
  };
}

/** Reads layout and returns the writes it decided on, if any. */
export type LayoutRead = () => (() => void) | void;

/** The reads waiting for one frame of one clock. */
type LayoutBatch = { clock: UiClock; reads: Set<LayoutRead>; cancel: CancelUiTimer };
let batch: LayoutBatch | undefined;

/**
 * Runs `read` before the next paint, in that frame's single read phase: every
 * scheduled read runs against one layout, then every write they returned.
 * Readers that wrote in their own frame callbacks forced a fresh layout for
 * the next reader; the scroll areas of a transcript measuring after a resize
 * laid the page out once each, in one frame.
 *
 * A batch belongs to the clock that scheduled its frame: a read scheduled
 * after another clock is installed waits for that clock's frame, not for one
 * the previous clock may never run.
 */
export function scheduleLayoutRead(read: LayoutRead): CancelUiTimer {
  if (batch?.clock !== current) batch = openBatch(current);
  const owner = batch;
  owner.reads.add(read);
  return () => {
    owner.reads.delete(read);
    if (owner.reads.size > 0) return;
    owner.cancel();
    if (batch === owner) batch = undefined;
  };
}

function openBatch(clock: UiClock): LayoutBatch {
  const opened: LayoutBatch = { clock, reads: new Set(), cancel: () => {} };
  opened.cancel = clock.frame(() => {
    // Reads scheduled by this frame's writes wait for the next one.
    if (batch === opened) batch = undefined;
    const reads = [...opened.reads];
    opened.reads.clear();
    runLayoutReads(reads);
  });
  return opened;
}

function runLayoutReads(reads: LayoutRead[]) {
  const writes: (() => void)[] = [];
  for (const read of reads) {
    isolate(() => {
      const write = read();
      if (write) writes.push(write);
    });
  }
  for (const write of writes) isolate(write);
}

// One reader's failure must not cost the others their measurement.
function isolate(run: () => void) {
  try {
    run();
  } catch (error) {
    queueMicrotask(() => {
      throw error;
    });
  }
}
