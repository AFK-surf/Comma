// Whether the page watches layout: a ResizeObserver or IntersectionObserver
// observing something, or a scroll listener. Only counted; the browser still
// delivers every callback itself, on a real frame (./virtual-time renders one
// when the page changed while something watches).

const observing = new Map<object, Set<Element>>();
// The scroll listeners each target has, by listener and capture: a listener
// removed that was added before the count started counts nothing.
const scrollListeners = new Map<EventTarget, Set<string | object>>();
const listenerKeys = new WeakMap<object, Map<boolean, object>>();

function listenerKey(
  listener: EventListenerOrEventListenerObject,
  options: boolean | EventListenerOptions | undefined
) {
  const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
  let byCapture = listenerKeys.get(listener);
  if (!byCapture) {
    byCapture = new Map();
    listenerKeys.set(listener, byCapture);
  }
  let key = byCapture.get(capture);
  if (!key) {
    key = {};
    byCapture.set(capture, key);
  }
  return key;
}
const scrollOffsets = new Map<EventTarget, string>();

function offsetOf(target: EventTarget) {
  if (target instanceof Element) return `${target.scrollLeft},${target.scrollTop}`;
  return `${window.scrollX},${window.scrollY}`;
}

/** True while an observer observes or a scroll listener listens. */
export function watchesLayout() {
  return observing.size > 0 || scrollListeners.size > 0;
}

/** True if a watched scroll offset moved since the last call. */
export function scrolledSinceLastCheck() {
  let scrolled = false;
  for (const target of scrollListeners.keys()) {
    const offset = offsetOf(target);
    if (scrollOffsets.get(target) !== offset) scrolled = true;
    scrollOffsets.set(target, offset);
  }
  return scrolled;
}

function countObservations(
  Observer: typeof ResizeObserver | typeof IntersectionObserver
) {
  const prototype = Observer.prototype as {
    observe(target: Element, options?: unknown): void;
    unobserve(target: Element): void;
    disconnect(): void;
  };
  const { disconnect, observe, unobserve } = prototype;
  prototype.observe = function (this: object, target: Element, options?: unknown) {
    const targets = observing.get(this) ?? new Set<Element>();
    targets.add(target);
    observing.set(this, targets);
    return observe.call(this, target, options);
  };
  prototype.unobserve = function (this: object, target: Element) {
    const targets = observing.get(this);
    targets?.delete(target);
    if (targets?.size === 0) observing.delete(this);
    return unobserve.call(this, target);
  };
  prototype.disconnect = function (this: object) {
    observing.delete(this);
    return disconnect.call(this);
  };
}

// Each IntersectionObserver with its callback. The browser computes their
// entries in its rendering step and queues their delivery as a task, whose
// order against other tasks is not fixed. The page's callback never runs from
// that task: what the browser delivers is kept, and after a frame the step
// gives the page the kept entries and those still queued (`takeRecords`), in
// that order, at a fixed point.
const intersectionCallbacks = new Map<
  IntersectionObserver,
  IntersectionObserverCallback
>();
const deliveredByBrowser = new Map<IntersectionObserver, IntersectionObserverEntry[]>();

/** Delivers the entries the last frame computed for each IntersectionObserver. */
export function deliverIntersections() {
  for (const [observer, callback] of intersectionCallbacks) {
    const records = [
      ...(deliveredByBrowser.get(observer) ?? []),
      ...observer.takeRecords(),
    ];
    deliveredByBrowser.delete(observer);
    if (records.length > 0) callback(records, observer);
  }
}

/** Installs the counts: in the page, before any page module. */
export function countLayoutWatchers() {
  const NativeIntersectionObserver = window.IntersectionObserver;
  window.IntersectionObserver = class extends NativeIntersectionObserver {
    constructor(
      callback: IntersectionObserverCallback,
      options?: IntersectionObserverInit
    ) {
      super((entries, observer) => {
        const kept = deliveredByBrowser.get(observer) ?? [];
        kept.push(...entries);
        deliveredByBrowser.set(observer, kept);
      }, options);
      intersectionCallbacks.set(this, callback);
    }

    override disconnect() {
      intersectionCallbacks.delete(this);
      deliveredByBrowser.delete(this);
      super.disconnect();
    }
  };
  countObservations(ResizeObserver);
  countObservations(IntersectionObserver);
  // The global object has its own addEventListener and removeEventListener.
  for (const target of [EventTarget.prototype, window] as EventTarget[]) {
    if (target === window && !Object.hasOwn(window, "addEventListener")) continue;
    const { addEventListener, removeEventListener } = target;
    target.addEventListener = function (
      this: EventTarget,
      type: string,
      ...rest: [
        EventListenerOrEventListenerObject | null,
        (boolean | AddEventListenerOptions)?,
      ]
    ) {
      if (type === "scroll" && rest[0]) {
        const listeners = scrollListeners.get(this) ?? new Set();
        listeners.add(listenerKey(rest[0], rest[1]));
        scrollListeners.set(this, listeners);
        scrollOffsets.set(this, offsetOf(this));
      }
      return addEventListener.call(this, type, ...rest);
    };
    target.removeEventListener = function (
      this: EventTarget,
      type: string,
      ...rest: [
        EventListenerOrEventListenerObject | null,
        (boolean | EventListenerOptions)?,
      ]
    ) {
      const listeners =
        type === "scroll" && rest[0] ? scrollListeners.get(this) : undefined;
      if (listeners && rest[0]) {
        listeners.delete(listenerKey(rest[0], rest[1]));
        if (listeners.size === 0) {
          scrollListeners.delete(this);
          scrollOffsets.delete(this);
        }
      }
      return removeEventListener.call(this, type, ...rest);
    };
  }
}
