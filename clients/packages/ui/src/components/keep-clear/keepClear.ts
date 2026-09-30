/**
 * Floating windows that others keep clear of, like the keep-clear areas an
 * Android picture-in-picture window avoids. The meeting recorder registers so
 * a floating video never rests on its recording controls; the video window
 * yields, the recorder never moves for it.
 */
const elements = new Set<HTMLElement>();
const listeners = new Set<() => void>();

const notify = () => {
  for (const listener of listeners) listener();
};

/** Returns the unregister function. */
export const registerKeepClearElement = (element: HTMLElement) => {
  elements.add(element);
  notify();
  return () => {
    elements.delete(element);
    notify();
  };
};

/** A registered element settled somewhere new or changed its size. */
export const keepClearElementMoved = notify;

export const keepClearRects = () =>
  Array.from(elements, (element) => element.getBoundingClientRect());

export const subscribeKeepClear = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
