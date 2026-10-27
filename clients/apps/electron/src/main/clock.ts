// Main's time: what it reads as now, and its timers. Main's modules take one (`realMainClock` by default), so a test
// gives its own clock that moves only when the test moves it.

export interface MainClock {
  /** Milliseconds since the epoch. */
  now(): number;
  /** Runs `run` once `ms` have passed; the returned function cancels it. A timer never keeps the app alive. */
  setTimer(ms: number, run: () => void): () => void;
}

export const realMainClock: MainClock = {
  now: () => Date.now(),
  setTimer: (ms, run) => {
    const timer = setTimeout(run, ms);
    timer.unref?.();
    return () => clearTimeout(timer);
  },
};

/** A signal that aborts once `ms` have passed on `clock` (`AbortSignal.timeout` on Main's clock). */
export function clockTimeoutSignal(clock: MainClock, ms: number): AbortSignal {
  const controller = new AbortController();
  clock.setTimer(ms, () =>
    controller.abort(new DOMException("The operation timed out.", "TimeoutError"))
  );
  return controller.signal;
}

/** Resolves once `ms` have passed on `clock`. */
export function clockSleep(clock: MainClock, ms: number): Promise<void> {
  return new Promise((resolve) => clock.setTimer(ms, resolve));
}

/** Runs `run` every `ms` on `clock`, the first time `ms` from now; the returned function stops it. */
export function clockInterval(
  clock: MainClock,
  ms: number,
  run: () => void
): () => void {
  let cancel: (() => void) | undefined;
  let stopped = false;
  const arm = () => {
    cancel = clock.setTimer(ms, () => {
      if (stopped) return;
      arm();
      run();
    });
  };
  arm();
  return () => {
    stopped = true;
    cancel?.();
  };
}
