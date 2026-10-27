import { useSyncExternalStore } from "react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";

// How often the day is checked. A timer set for midnight is not enough: a
// computer that sleeps through the night pauses it, so the day would turn
// only that long after waking.
const DAY_CHECK_MS = 60_000;

/** The local midnight that starts the day `timestamp` (ms) falls in. */
export function startOfLocalDay(timestamp: number) {
  const date = new Date(timestamp);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

// One check shared by every subscriber, stopped when none is left.
const listeners = new Set<() => void>();
let day = startOfLocalDay(uiClock.now());
let timer: CancelUiTimer | undefined;

function subscribe(listener: () => void) {
  listeners.add(listener);
  if (timer === undefined) {
    day = startOfLocalDay(uiClock.now());
    timer = uiClock.every(DAY_CHECK_MS, () => {
      const next = startOfLocalDay(uiClock.now());
      if (next === day) return;
      day = next;
      for (const notify of listeners) notify();
    });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      timer?.();
      timer = undefined;
    }
  };
}

const today = () => startOfLocalDay(uiClock.now());

/**
 * The start of today (local midnight, ms), re-rendering the caller when the
 * day changes, so labels such as "Today" do not outlive the day they name.
 */
export function useStartOfToday() {
  return useSyncExternalStore(subscribe, today);
}
