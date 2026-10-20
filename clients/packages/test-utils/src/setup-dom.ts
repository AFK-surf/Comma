import "@testing-library/jest-dom/vitest";
// React Aria patches `HTMLElement.prototype.focus` when this module loads, as
// a page runs its scripts before anyone interacts. Loaded here, it does so
// before a test's user-event replaces `focus` with a getter (user-event's
// `patchFocus`), also when a later file of a shared process loads React Aria
// for the first time.
import "react-aria/private/interactions/useFocusVisible";
import { act, cleanup } from "@testing-library/react";
import { toast } from "sonner";
import { afterAll, afterEach, beforeEach, vi } from "vitest";
import { baseLocale, initializeCommaI18n } from "@comma/i18n";
import { stopTimersOfEndedTests } from "./ended-test-timers";
import { stepUserEventOnTestClock } from "./user-event-clock";

stopTimersOfEndedTests();
stepUserEventOnTestClock();

// Where each test starts, as a page load would: the address the file's window
// opened at.
const startUrl = window.location.href;

// And the root element's attributes (lang, theme) as the file's modules left
// them, read before its first test.
let rootAttributes: [string, string][] | undefined;
beforeEach(() => {
  rootAttributes ??= Array.from(document.documentElement.attributes, (attribute) => [
    attribute.name,
    attribute.value,
  ]);
});

// sonner adds its own stylesheet (97 rules) to the head when it loads. jsdom
// lays nothing out, yet each getComputedStyle matches every rule on the page,
// and role queries (accessible names, visibility) and user-event's
// pointer-events check call it for an element and each of its ancestors: the
// sheet doubled that cost. No test reads a toast's computed style, so the page
// starts without it.
for (const style of Array.from(document.head.querySelectorAll("style")))
  if (style.textContent?.includes("[data-sonner-toaster]")) style.remove();

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

// The files of the `jsdom-shared` project run one after another in one
// process and on one page (vitest.config.ts `sharedDomFiles`). Each starts
// where a page load would put it: at the page's first address, with an empty
// body, a head without the stylesheets earlier files added, and a navigator
// without what an earlier file's user-event added (its clipboard stub, which
// user-event removes only after the first file).
type FirstPage = { url: string; navigator: Set<PropertyKey> };
const firstPageKey = Symbol.for("comma.test.firstPage");
const pageScope = globalThis as { [firstPageKey]?: FirstPage };
const firstPage = (pageScope[firstPageKey] ??= {
  url: window.location.href,
  navigator: new Set(Reflect.ownKeys(navigator)),
});
window.history.replaceState(null, "", firstPage.url);
document.body.replaceChildren();
// jsdom keeps the sheet of a <style> that left the document inside a removed
// subtree (a component's own <style>, unmounted) in `document.styleSheets`,
// where every later getComputedStyle still matches its rules. Removing the
// element itself drops the sheet.
for (const sheet of Array.from(document.styleSheets)) {
  const owner = sheet.ownerNode;
  if (owner && !owner.isConnected) {
    document.head.append(owner);
    owner.remove();
  }
}
document.head.replaceChildren(jsdomCustomPropertyFloor);
for (const name of document.body.getAttributeNames())
  document.body.removeAttribute(name);
for (const key of Reflect.ownKeys(navigator))
  if (!firstPage.navigator.has(key)) Reflect.deleteProperty(navigator, key);

// Globals and environment variables a file stubbed end with it.
afterAll(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

globalThis.ResizeObserver = ResizeObserverMock;
globalThis.IntersectionObserver = IntersectionObserverMock;
(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

/**
 * sonner arms a bare `setTimeout(removeToast, TIME_BEFORE_UNMOUNT)` when a
 * toast closes and never clears it on unmount. It is a timer of the fake clock
 * (test-clock.ts), so the drain after each test below runs it while the window
 * is still there.
 */
afterEach(() => {
  cleanup();
  // sonner keeps its toasts in one module-wide store and replays the active
  // ones to a Toaster that mounts later, as a window's single Toaster should.
  // A test's toasts must not reach the next test's Toaster.
  toast.dismiss();
  // Time passes after a test as it would for a user: what the test left on the
  // clock (a library's deferred cleanup, React's last work) runs before the
  // next test starts, not during it. Timers that keep rearming stop after a
  // fixed number of rounds.
  for (let round = 0; round < 20 && vi.getTimerCount() > 0; round += 1)
    act(() => vi.runOnlyPendingTimers());
  globalThis.localStorage.clear();
  globalThis.sessionStorage.clear();
  // Paraglide keeps the active locale in module state, which the next test
  // shares; a test that switched to another language must not leave it.
  initializeCommaI18n([baseLocale], { documentLanguage: false });
  Reflect.deleteProperty(globalThis, "commaNative");
  // A page load starts at its address.
  window.history.replaceState(null, "", startUrl);
  const root = document.documentElement;
  for (const name of root.getAttributeNames()) root.removeAttribute(name);
  for (const [name, value] of rootAttributes ?? []) root.setAttribute(name, value);
});
