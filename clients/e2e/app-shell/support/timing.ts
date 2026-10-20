import { commands } from "vitest/browser";
import { timingEnabled } from "./record";

// Where a browser component test's real time goes (DETERMINISM_TIMING): the
// browser's reset, opening its page, the fixture's mount (of it, loading the
// fixture's module and its first render), the test's own
// steps, the real frames the page waited for within them, checking and
// recording its end, closing the page; and per file, the warm-up.

type Phase = "reset" | "open" | "mount" | "steps" | "end" | "close" | "warmUp";

// A mount a test's steps make (a goto in its body) is counted as mount, not
// as steps.
let inSteps = false;
let mountInSteps = 0;

let phases: Partial<Record<Phase, number>> = {};
let warmUp = 0;
let frames = { count: 0, time: 0, reasons: {} as Record<string, number> };
let mountTimes = { load: 0, render: 0 };

/** Starts a test's phases. */
export function startTiming() {
  phases = {};
  frames = { count: 0, time: 0, reasons: {} };
  mountTimes = { load: 0, render: 0 };
  mountInSteps = 0;
}

/** The real frames the test's page waited for, and the real time its mount took. */
export function pageTimeSpent(
  nativeFrames: { count: number; time: number; reasons: Record<string, number> },
  mounts: { load: number; render: number }
) {
  frames = { ...nativeFrames, reasons: { ...nativeFrames.reasons } };
  mountTimes = { ...mounts };
}

/**
 * Real time, only to report where it went: it is written to the
 * DETERMINISM_TIMING output alone, never to the execution record or its
 * digest, and neither the test page nor the test's steps can read it.
 */
export function realNow() {
  // ast-grep-ignore: ts-test-clock
  return performance.now();
}

/** Runs `run`, counting its real time to `phase`. */
export async function timed<T>(phase: Phase, run: () => Promise<T>): Promise<T> {
  const start = realNow();
  if (phase === "steps") inSteps = true;
  try {
    return await run();
  } finally {
    const spent = realNow() - start;
    phases[phase] = (phases[phase] ?? 0) + spent;
    if (phase === "steps") inSteps = false;
    if (phase === "mount" && inSteps) mountInSteps += spent;
  }
}

/** The file's warm-up, reported with each of its tests. */
export function warmedUp(ms: number) {
  warmUp += ms;
}

const round = (ms = 0) => Math.round(ms);

/** Reports the test's phases. */
export async function reportTiming(file: string, test: string) {
  const reported = phases;
  if (!(await timingEnabled())) return;
  await commands.reportTiming(
    JSON.stringify({
      file,
      test,
      reset: round(reported.reset),
      open: round(reported.open),
      mount: round(reported.mount),
      mountLoad: round(mountTimes.load),
      mountRender: round(mountTimes.render),
      steps: round((reported.steps ?? 0) - mountInSteps),
      frames: frames.count,
      frameTime: round(frames.time),
      frameReasons: frames.reasons,
      end: round(reported.end),
      close: round(reported.close),
      warmUp: round(warmUp),
    })
  );
}
