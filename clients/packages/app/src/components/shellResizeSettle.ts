import { getNativeBridge } from "@comma/native-bridge";
import { useEffect } from "react";

// Quiet period that stands in for the native end-of-resize signal. Main
// reports the end of a live resize on macOS and Windows (`resized`); the web
// build and Linux only ever see a `resize` stream that stops, and a
// programmatic resize emits no end signal anywhere — so the timer always
// backs the signal up rather than gating on it. A pointer pressed inside the
// page settles it too: the window edge has been let go by then.
const windowResizeQuietPeriodMs = 500;

// While the window is being dragged the shell tracks it 1:1; anything with a
// width transition has to stand down for the duration or it chases the drag a
// frame and a half behind (see styles.css).
const windowResizingClass = "comma-window-is-resizing";

let windowResizing = false;
const windowResizingListeners = new Set<() => void>();

function setWindowResizing(next: boolean) {
  if (next === windowResizing) return;
  windowResizing = next;
  document.body.classList.toggle(windowResizingClass, next);
  for (const listener of windowResizingListeners) listener();
}

/** Whether a window resize is in flight (see `useWindowResizingFlag`). */
export function isWindowResizing() {
  return windowResizing;
}

/** Called when a window resize starts and when it settles. */
export function subscribeWindowResizing(listener: () => void) {
  windowResizingListeners.add(listener);
  return () => {
    windowResizingListeners.delete(listener);
  };
}

/**
 * Marks the document while a window resize is in flight.
 *
 * The Chat Sidebar's width is a function of the window (it yields once the
 * product route reaches its minimum), and its 150ms width transition is only
 * suppressed for its own pointer drag. Left on through a window drag, every
 * frame restarts that transition, so the sidebar — and the native browser
 * view that tracks its box — trails the window edge and the chat column
 * beside it re-wraps on every frame of the chase.
 *
 * The mark flips twice per drag, never per frame: its readers (the body class
 * and `subscribeWindowResizing`) hear the start and the settle only.
 */
export function useWindowResizingFlag() {
  useEffect(() => {
    let quietTimer: number | undefined;
    const cancelQuietClear = () => {
      if (quietTimer === undefined) return;
      window.clearTimeout(quietTimer);
      quietTimer = undefined;
    };
    const handleResize = () => {
      setWindowResizing(true);
      cancelQuietClear();
      quietTimer = window.setTimeout(() => {
        quietTimer = undefined;
        setWindowResizing(false);
      }, windowResizeQuietPeriodMs);
    };
    const settle = () => {
      cancelQuietClear();
      setWindowResizing(false);
    };
    const unsubscribe = getNativeBridge().surfaces.onWindowResizeSettled(settle);
    window.addEventListener("resize", handleResize);
    window.addEventListener("pointerdown", settle, true);
    return () => {
      settle();
      window.removeEventListener("resize", handleResize);
      window.removeEventListener("pointerdown", settle, true);
      unsubscribe();
    };
  }, []);
}
