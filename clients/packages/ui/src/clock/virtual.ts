import type { CancelUiTimer, UiClock } from "./index";

/**
 * A UI clock that moves only when a test steps it. Timers run at their due
 * time in the order they were set; frames fall on multiples of `frameMs` and
 * run the frame callbacks requested before that frame. When a timer and a
 * frame are due at the same time, the timer runs first.
 */
export type VirtualUiClock = UiClock & {
  /** Runs `ms` of time: every timer and frame due in it, in order. */
  advance(ms: number): void;
  /** Runs `count` frames: time moves to the end of the `count`th next frame. */
  advanceFrames(count: number): void;
  /** Number of timers and frame callbacks waiting. */
  pending(): number;
};

type Timer = {
  at: number;
  seq: number;
  run: () => void;
  interval: number | null;
};

export function createVirtualUiClock({
  start = Date.UTC(2026, 0, 1),
  frameMs = 16,
}: { start?: number; frameMs?: number } = {}): VirtualUiClock {
  let elapsed = 0;
  /** Time of the last frame that ran; time 0 counts as a frame. */
  let lastFrame = 0;
  let seq = 0;
  const timers = new Set<Timer>();
  let frames = new Map<number, (time: number) => void>();

  const nextTimer = () => {
    let next: Timer | null = null;
    for (const timer of timers)
      if (!next || timer.at < next.at || (timer.at === next.at && timer.seq < next.seq))
        next = timer;
    return next;
  };
  // The first frame boundary at or after now that has not run yet: a timer that
  // lands on a boundary does not swallow that boundary's frame.
  const nextFrameAt = () => {
    const at = Math.ceil(elapsed / frameMs) * frameMs;
    return at > lastFrame ? at : lastFrame + frameMs;
  };
  const schedule = (ms: number, run: () => void, interval: number | null) => {
    const timer: Timer = {
      at: elapsed + Math.max(0, ms),
      seq: (seq += 1),
      run,
      interval,
    };
    timers.add(timer);
    return timer;
  };

  const runUntil = (target: number) => {
    for (;;) {
      const timer = nextTimer();
      const frameAt = frames.size > 0 ? nextFrameAt() : Infinity;
      if (timer && timer.at <= target && timer.at <= frameAt) {
        elapsed = Math.max(elapsed, timer.at);
        if (timer.interval === null) timers.delete(timer);
        else {
          timer.at += Math.max(1, timer.interval);
          timer.seq = seq += 1;
        }
        timer.run();
      } else if (frameAt <= target) {
        elapsed = frameAt;
        lastFrame = frameAt;
        const due = frames;
        frames = new Map();
        for (const run of due.values()) run(elapsed);
      } else break;
    }
    elapsed = target;
  };

  return {
    now: () => start + elapsed,
    monotonic: () => elapsed,
    after(ms, run): CancelUiTimer {
      const timer = schedule(ms, run, null);
      return () => timers.delete(timer);
    },
    every(ms, run): CancelUiTimer {
      const timer = schedule(Math.max(1, ms), run, ms);
      return () => timers.delete(timer);
    },
    frame(run): CancelUiTimer {
      const id = (seq += 1);
      frames.set(id, run);
      return () => frames.delete(id);
    },
    advance(ms) {
      runUntil(elapsed + ms);
    },
    advanceFrames(count) {
      for (let i = 0; i < count; i += 1) {
        const at = nextFrameAt();
        runUntil(at);
        lastFrame = at;
      }
    },
    pending: () => timers.size + frames.size,
  };
}
