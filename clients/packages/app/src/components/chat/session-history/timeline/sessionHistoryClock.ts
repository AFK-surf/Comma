import { useRef, useSyncExternalStore } from "react";

// A shared presentation clock, not a refresh loop: no network or record mutation.
// At most one timer per renderer, stopped when no visible history view needs it.
// TLA: tla/session-history/ExecutionHistoryObservation.tla::Tick.
const listeners = new Set<() => void>();
let now = Date.now();
let timer: ReturnType<typeof setInterval> | undefined;
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (timer === undefined) {
    now = Date.now();
    timer = setInterval(() => {
      now = Date.now();
      for (const notify of listeners) notify();
    }, 100);
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      clearInterval(timer);
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
