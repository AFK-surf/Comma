import { motionDuration } from "@comma/ui";
import { useEffect, useState } from "react";

type Swap<T> = { at: number; from: T; to: T };

/**
 * The value `value` just moved away from, for `durationMs` after the move;
 * `undefined` while nothing is leaving. Derived during render, so an element
 * keyed by the old value keeps its node through the change and transitions
 * out from where it stands instead of being remounted as a fresh copy.
 *
 * A duration that has to be read from the page is passed as a function. It is
 * resolved when a move arms the timer, never while rendering: a computed-style
 * read flushes the document's pending style work, and these hosts render on
 * every streamed delta.
 */
export function useLeaving<T>(
  value: T,
  durationMs: number | (() => number)
): T | undefined {
  const [settled, setSettled] = useState(value);
  const [swap, setSwap] = useState<Swap<T>>();
  if (!Object.is(settled, value)) {
    setSettled(value);
    setSwap({ at: Date.now(), from: settled, to: value });
  }
  useEffect(() => {
    if (!swap) return undefined;
    const timer = window.setTimeout(
      () => setSwap(undefined),
      typeof durationMs === "function" ? durationMs() : durationMs
    );
    return () => window.clearTimeout(timer);
  }, [durationMs, swap]);
  return swap && Object.is(swap.to, value) ? swap.from : undefined;
}

/**
 * A motion duration token read off the root, so the unmount timer follows the
 * stylesheet (a slowed-down token slows the timer too); `fallbackMs` stands in
 * where no stylesheet is loaded.
 */
export function motionDurationMs(token: string, fallbackMs: number): number {
  if (typeof document === "undefined") return fallbackMs;
  const raw = getComputedStyle(document.documentElement).getPropertyValue(token).trim();
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallbackMs;
  return raw.endsWith("ms") ? parsed : parsed * 1000;
}

/** How long a state that was just left stays mounted for its exit. */
export function stateSwapExitMs(): number {
  return motionDurationMs(
    "--motion-duration-state-swap-exit",
    motionDuration.stateSwapExit
  );
}
