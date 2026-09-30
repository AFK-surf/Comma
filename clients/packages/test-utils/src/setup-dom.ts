import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, vi } from "vitest";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() {
    return this.values.size;
  }

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  key(index: number) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, String(value));
  }
}

class ResizeObserverMock implements ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}

// jsdom has no layout. Treat observed nodes as visible by default; visibility
// tests replace this observer with explicit entries. Browsers verify clipping.
class IntersectionObserverMock implements IntersectionObserver {
  readonly root = null;
  readonly rootMargin = "0px";
  readonly scrollMargin = "0px";
  readonly thresholds = [0];
  private targets = new Set<Element>();
  constructor(private callback: IntersectionObserverCallback) {}
  observe(target: Element) {
    this.targets.add(target);
    queueMicrotask(() => {
      if (!this.targets.has(target)) return;
      const rect = target.getBoundingClientRect();
      this.callback(
        [
          {
            target,
            isIntersecting: true,
            intersectionRatio: 1,
            boundingClientRect: rect,
            intersectionRect: rect,
            rootBounds: null,
            time: performance.now(),
          },
        ],
        this
      );
    });
  }
  unobserve(target: Element) {
    this.targets.delete(target);
  }
  disconnect() {
    this.targets.clear();
  }
  takeRecords(): IntersectionObserverEntry[] {
    return [];
  }
}

function isUsableStorage(value: unknown): value is Storage {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as Storage).clear === "function" &&
    typeof (value as Storage).getItem === "function" &&
    typeof (value as Storage).setItem === "function" &&
    typeof (value as Storage).removeItem === "function"
  );
}

function ensureStorage(
  target: typeof globalThis,
  key: "localStorage" | "sessionStorage"
) {
  if (isUsableStorage(target[key])) {
    return;
  }

  Object.defineProperty(target, key, {
    configurable: true,
    value: new MemoryStorage(),
  });
}

ensureStorage(globalThis, "localStorage");
ensureStorage(globalThis, "sessionStorage");

if (typeof window !== "undefined") {
  ensureStorage(window, "localStorage");
  ensureStorage(window, "sessionStorage");
}

// jsdom dispatches pointer events but does not implement pointer capture;
// sonner's toast drag handlers call these on pointerdown.
if (typeof Element !== "undefined") {
  const elementPrototype = Element.prototype as Element & {
    hasPointerCapture?: (pointerId: number) => boolean;
    releasePointerCapture?: (pointerId: number) => void;
    setPointerCapture?: (pointerId: number) => void;
  };
  elementPrototype.hasPointerCapture ??= () => false;
  elementPrototype.releasePointerCapture ??= () => {};
  elementPrototype.setPointerCapture ??= () => {};
  // jsdom has no animation engine, so there are no running animations to
  // return. Tests of animation behavior supply their own animation objects.
  elementPrototype.getAnimations ??= () => [];
  // cmdk keeps the keyboard-selected option visible. jsdom has no layout and
  // therefore omits this browser method entirely; component tests that care
  // about the call replace it with a spy.
  const scrollableElementPrototype = elementPrototype as Element & {
    scrollIntoView?: (arg?: boolean | ScrollIntoViewOptions) => void;
  };
  scrollableElementPrototype.scrollIntoView ??= () => {};
}

// jsdom runs no layout, so Range carries none of the CSSOM View geometry that
// selection-anchored UI reads. A zero rect and no client rects are the honest
// answer for a DOM with no boxes; a test that needs real geometry stubs these
// with its own rects.
if (typeof Range !== "undefined") {
  const rangePrototype = Range.prototype as Range & {
    getBoundingClientRect?: () => DOMRect;
    getClientRects?: () => DOMRectList;
  };
  rangePrototype.getBoundingClientRect ??= () => new DOMRect(0, 0, 0, 0);
  rangePrototype.getClientRects ??= () =>
    Object.assign([], { item: () => null }) as unknown as DOMRectList;
}

/**
 * jsdom resolves an UNDEFINED custom property by re-walking every ancestor per
 * ancestor, so the cost is exponential in DOM depth: a lookup that takes ~3ms
 * when the property is defined takes seconds at the depth the product shell
 * reaches. Components read these three during render (dropdown popovers, the
 * chat thread), so define them once at the root with the values their readers
 * already treat as "unset" — no behaviour changes, the cliff disappears.
 */
const jsdomCustomPropertyFloor = document.createElement("style");
jsdomCustomPropertyFloor.textContent = `:root {
  --comma-overlay-safe-top: 0px;
  --comma-chat-user-bubble-collapsed-block-size: none;
  --comma-chat-thread-top-inset: none;
}`;
document.head.append(jsdomCustomPropertyFloor);

globalThis.ResizeObserver = ResizeObserverMock;
globalThis.IntersectionObserver = IntersectionObserverMock;
(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

/**
 * sonner arms a bare `setTimeout(removeToast, TIME_BEFORE_UNMOUNT)` when a
 * toast closes and never clears it on unmount. Once the file's environment is
 * torn down that callback still runs, reaches React's `resolveUpdatePriority`,
 * and throws `ReferenceError: window is not defined` — an unhandled error that
 * fails the run while every test reports green. Drain it, and only for a test
 * that actually rendered a toaster, so nothing else pays for the wait.
 */
const SONNER_UNMOUNT_DRAIN_MS = 250;

afterEach(async () => {
  const toasted = document.querySelector("[data-sonner-toaster]") !== null;
  cleanup();
  if (toasted) {
    await new Promise((settle) => {
      setTimeout(settle, SONNER_UNMOUNT_DRAIN_MS);
    });
  }
  globalThis.localStorage.clear();
  globalThis.sessionStorage.clear();
  vi.useRealTimers();
  Reflect.deleteProperty(globalThis, "commaNative");
});
