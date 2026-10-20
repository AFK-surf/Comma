import { useRef, useSyncExternalStore } from "react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";

// A shared presentation clock, not a refresh loop: no network or record mutation.
// At most one timer per renderer, stopped when no visible history view needs it.
const listeners = new Set<() => void>();
let now = uiClock.now();
let timer: CancelUiTimer | undefined;
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (timer === undefined) {
    now = uiClock.now();
    timer = uiClock.every(100, () => {
      now = uiClock.now();
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
const inactive = () => () => {};
export function useSessionHistoryClock(enabled = true) {
  const last = useRef(0);
  const snapshot = useSyncExternalStore(enabled ? subscribe : inactive, () =>
    enabled ? now : last.current
  );
  if (enabled) last.current = snapshot;
  return snapshot;
}
