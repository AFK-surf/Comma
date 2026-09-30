/**
 * Hands IntersectionObserver visibility to the test: nothing is in view until
 * the test reveals it. jsdom has no layout, and the default stub (setup-dom)
 * reports every observed node visible, which cannot tell "the reader scrolled
 * to it" from "it mounted".
 */
export function controlIntersections() {
  const visible = new Set<Element>();
  const observers = new Set<ControlledIntersectionObserver>();
  const original = globalThis.IntersectionObserver;

  class ControlledIntersectionObserver implements IntersectionObserver {
    readonly root = null;
    readonly rootMargin = "0px";
    readonly scrollMargin = "0px";
    readonly thresholds = [0];
    readonly targets = new Set<Element>();
    constructor(private callback: IntersectionObserverCallback) {
      observers.add(this);
    }
    observe(target: Element) {
      this.targets.add(target);
      // A browser reports a new target's state once, whatever it is.
      queueMicrotask(() => this.report(target));
    }
    unobserve(target: Element) {
      this.targets.delete(target);
    }
    disconnect() {
      this.targets.clear();
      observers.delete(this);
    }
    takeRecords(): IntersectionObserverEntry[] {
      return [];
    }
    report(target: Element) {
      if (!this.targets.has(target)) return;
      const rect = target.getBoundingClientRect();
      const isIntersecting = visible.has(target);
      this.callback(
        [
          {
            target,
            isIntersecting,
            intersectionRatio: isIntersecting ? 1 : 0,
            boundingClientRect: rect,
            intersectionRect: rect,
            rootBounds: null,
            time: performance.now(),
          },
        ],
        this
      );
    }
  }

  const set = (target: Element, inView: boolean) => {
    if (inView) visible.add(target);
    else visible.delete(target);
    for (const observer of observers) observer.report(target);
  };
  globalThis.IntersectionObserver = ControlledIntersectionObserver;
  return {
    reveal: (target: Element) => set(target, true),
    hide: (target: Element) => set(target, false),
    restore: () => {
      globalThis.IntersectionObserver = original;
    },
  };
}
