import "@comma/test-utils/browser-commands";
import {
  queryAllByLabelText,
  queryAllByRole,
  queryAllByText,
  type ByRoleOptions,
} from "@testing-library/dom";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect as baseExpect,
  inject,
  it,
  type Assertion,
} from "vitest";
import { commands, page as browserPage } from "vitest/browser";
import {
  pageWindow,
  reloadTestPage,
  reopenTestPage,
  setPageRuntime,
  setPageSeed,
  runningClock,
  startTestClock,
  testPage,
  testClock,
  stepUntil,
  stepUntilSettled,
  stopTestClock,
} from "./virtual-time";
import {
  forgetWorld,
  openPageWorld,
  pageMountedInWorld,
  type NodeRealm,
} from "./world";
import {
  expectFrameLocator,
  FrameElementLocator,
  FrameLocator,
  forgetFrames,
} from "./frames";
import { beginRecord, endRecord } from "./record";
import { seedFor, workerSeedParameter } from "./random";
import { worldRequestParameter } from "../../ui-runtime/realm-names";
import { externalFiles } from "../fixtures/external-files";
import {
  pageTimeSpent,
  realNow,
  reportTiming,
  startTiming,
  timed,
  warmedUp,
} from "./timing";
import type { FakeMediaSources } from "./fake-media";

// The component fixtures under e2e/app-shell run in the Vitest browser
// project: one real Chromium, no fixture build, server or page load per spec.
// This module gives those specs the small part of Playwright's page, locator
// and assertion API they use. Elements resolve in the test frame's DOM, actions
// wait for Playwright's actionability (attached, visible, stable, enabled) and
// then drive trusted input through browser commands.

// A wait gives up after ten seconds of test-clock time
// (docs/testing.md#deterministic-tests): it fails on the same frame on every
// machine, with what it last saw. A spec's own `timeout` changes the bound.
const defaultTimeout = 10_000;
const actionTimeout = 10_000;

// A wait moves page time: each step of it is one test-clock frame, so what a
// wait sees never depends on how fast the machine is. Nothing waits on real
// time: outside a test's page there is no clock to step, and a wait there is
// an error.
const clockOrFail = () => {
  const clock = runningClock();
  if (!clock) throw new Error("No test page is open: nothing can wait.");
  return clock;
};
// A frame passes: what an action needs before it looks again (an element
// that must stay where it is for a frame).
const waitStep = () => clockOrFail().advanceFrames(1);
// A wait for something to hold moves to the next time anything is due: it
// can hold no sooner. With nothing due, a frame, so a wait that cannot end
// still reaches its limit.
const waitNext = async () => {
  if (!(await clockOrFail().advanceToNext(60_000)))
    await clockOrFail().advanceFrames(1);
};
const stepFor = (ms: number) => clockOrFail().advance(ms);
const waitNow = () => clockOrFail().elapsed();
// After trusted input, Chromium renders a frame before the step: the event's
// default action (a scroll, a hover style) shows in it.
const inputStep = () => clockOrFail().afterInput();

// The running test's page (./virtual-time): where its fixture renders, its
// locators resolve and what it evaluates runs.
const win = () => pageWindow();
const doc = () => win().document;
// A function the test evaluates runs in its page, as Playwright runs one: made
// again there from its source, it sees the page's globals and only its
// arguments, never the test's variables.
/** What `storage` holds, by key. */
const storageEntries = (storage: Storage) =>
  Object.fromEntries(
    Array.from({ length: storage.length }, (_, index) => {
      const key = storage.key(index)!;
      return [key, storage.getItem(key)!];
    })
  );

// By document: a reloaded frame keeps its window, not its globals.
const compiled = new WeakMap<Document, Map<string, unknown>>();
function inPage<F extends (...args: never[]) => unknown>(fn: F): F {
  const page = win();
  let cache = compiled.get(page.document);
  if (!cache) {
    cache = new Map();
    compiled.set(page.document, cache);
  }
  const source = fn.toString();
  let made = cache.get(source);
  if (!made) {
    made = (page as unknown as { eval(code: string): unknown }).eval(`(${source})`);
    cache.set(source, made);
  }
  return made as F;
}

// A page on the UI runtime (../../ui-runtime/child) sends the input: it knows
// what each one makes the browser send it, and waits for that.
const sendInput = <T>(name: string, args: unknown[], send: () => Promise<T>) => {
  const page = runningClock() ? testPage() : undefined;
  return page?.input ? page.input(name, args, send) : send();
};

// What a test evaluates in its page may wait there for work it started (a
// React update to commit). A page on the UI runtime runs that work itself,
// without moving page time, so the wait can end; elsewhere it runs on the
// page's own tasks. What does not wait is left for the test's next step.
function evaluated<R>(result: R): R | Promise<Awaited<R>> {
  const page = runningClock() ? testPage() : undefined;
  const pending = result as { then?: unknown; catch?: (handle: () => void) => void };
  if (!page?.settle || typeof pending?.then !== "function") return result;
  // A rejection is the caller's to see, once the page has settled.
  pending.catch?.(() => undefined);
  // A fixture whose evaluations wait for the page's frames or animations
  // steps page time until they resolve, as a browser's own time would run.
  if (evaluationsStep)
    return page.settle().then(() => stepUntilSettled(result as Promise<Awaited<R>>));
  return page.settle().then(() => result as Awaited<R>);
}

// Trusted input, each event followed by one test-clock frame, as a browser
// handles input before its next frame: what a test reads after an input never
// depends on how much real time passed.
let lastPointer: { x: number; y: number } | undefined;
const input = {
  async mouseMove(x: number, y: number, steps = 1) {
    const from = lastPointer ?? { x, y };
    for (let step = 1; step <= steps; step += 1) {
      const at = {
        x: from.x + ((x - from.x) * step) / steps,
        y: from.y + ((y - from.y) * step) / steps,
      };
      await sendInput("mouseMove", [at.x, at.y], () => commands.mouseMove(at.x, at.y));
      lastPointer = at;
      if (runningClock()) testPage().setPointer(at);
      await inputStep();
    }
  },
  async mouseDown(button?: "left" | "right" | "middle", clickCount = 1) {
    await sendInput("mouseDown", [button], () =>
      commands.mouseDown(button ?? "left", clickCount)
    );
    await inputStep();
  },
  async mouseUp(button?: "left" | "right" | "middle", clickCount = 1) {
    await sendInput("mouseUp", [button], () =>
      commands.mouseUp(button ?? "left", clickCount)
    );
    await inputStep();
  },
  async mouseWheel(deltaX: number, deltaY: number) {
    await sendInput("mouseWheel", [deltaX, deltaY], () =>
      commands.mouseWheel(deltaX, deltaY)
    );
    await inputStep();
  },
  async keyboardPress(key: string, delay?: number) {
    if (delay) {
      await input.keyboardDown(key);
      await stepFor(delay);
      await input.keyboardUp(key);
      return;
    }
    await sendInput("keyboardPress", [key], () => commands.keyboardPress(key));
    await inputStep();
  },
  async keyboardDown(key: string) {
    await sendInput("keyboardDown", [key], () => commands.keyboardDown(key));
    await inputStep();
  },
  async keyboardUp(key: string) {
    await sendInput("keyboardUp", [key], () => commands.keyboardUp(key));
    await inputStep();
  },
  async keyboardType(text: string, delay?: number) {
    for (const character of text) {
      await sendInput("keyboardType", [character], () =>
        commands.keyboardType(character)
      );
      await (delay ? stepFor(delay) : waitStep());
    }
  },
  async keyboardInsertText(text: string) {
    await sendInput("keyboardInsertText", [text], () =>
      commands.keyboardInsertText(text)
    );
    await inputStep();
  },
};
const normalize = (value: string) => value.replace(/\s+/g, " ").trim();

type TextMatcher = string | RegExp;
const matchesText = (actual: string, expected: TextMatcher, exact = false) =>
  typeof expected === "string"
    ? exact
      ? normalize(actual) === normalize(expected)
      : normalize(actual).toLowerCase().includes(normalize(expected).toLowerCase())
    : expected.test(actual);

const isVisible = (element: Element) =>
  element.isConnected &&
  element.checkVisibility({ visibilityProperty: true, opacityProperty: false }) &&
  (() => {
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  })();

type Query = (root: ParentNode) => Element[];

export type BoundingBox = { x: number; y: number; width: number; height: number };

type ClickOptions = {
  button?: "left" | "right" | "middle";
  clickCount?: number;
  force?: boolean;
  modifiers?: string[];
  position?: { x: number; y: number };
  timeout?: number;
  delay?: number;
  trial?: boolean;
  enabled?: boolean;
};

export class Locator {
  constructor(
    private readonly query: Query,
    readonly description: string
  ) {}

  /** Every element the locator matches now, in document order. */
  resolve(): Element[] {
    return this.query(doc());
  }

  private chain(query: (element: Element) => Element[], description: string) {
    return new Locator((root) => {
      const seen = new Set<Element>();
      const result: Element[] = [];
      for (const element of this.query(root)) {
        for (const child of query(element)) {
          if (!seen.has(child)) {
            seen.add(child);
            result.push(child);
          }
        }
      }
      return sortInDocumentOrder(result);
    }, `${this.description} >> ${description}`);
  }

  locator(selector: string | Locator, options: FilterOptions = {}): Locator {
    const located =
      typeof selector === "string"
        ? this.chain((element) => selectAll(element, selector), selector)
        : this.chain(
            (element) => selector.resolve().filter((match) => element.contains(match)),
            selector.description
          );
    return Object.keys(options).length ? located.filter(options) : located;
  }

  getByRole(role: string, options: RoleOptions = {}) {
    return this.chain((element) => byRole(element, role, options), `role=${role}`);
  }

  getByTestId(id: string | RegExp) {
    return this.chain(
      (element) =>
        deepQueryAll(element, "[data-testid]").filter((match) =>
          typeof id === "string"
            ? match.getAttribute("data-testid") === id
            : id.test(match.getAttribute("data-testid") ?? "")
        ),
      `testid=${id}`
    );
  }

  getByText(text: TextMatcher, options: { exact?: boolean } = {}) {
    return this.chain(
      (element) => byText(element, text, options.exact),
      `text=${text}`
    );
  }

  getByLabel(text: TextMatcher, options: { exact?: boolean } = {}) {
    return this.chain(
      (element) => byLabel(element, text, options.exact),
      `label=${text}`
    );
  }

  getByPlaceholder(text: TextMatcher, options: { exact?: boolean } = {}) {
    return this.chain(
      (element) =>
        [...element.querySelectorAll("[placeholder]")].filter((match) =>
          matchesText(match.getAttribute("placeholder") ?? "", text, options.exact)
        ),
      `placeholder=${text}`
    );
  }

  filter(options: FilterOptions): Locator {
    return new Locator(
      (root) =>
        this.query(root).filter((element) => {
          if (
            options.hasText !== undefined &&
            !matchesText(element.textContent ?? "", options.hasText)
          ) {
            return false;
          }
          if (
            options.hasNotText !== undefined &&
            matchesText(element.textContent ?? "", options.hasNotText)
          ) {
            return false;
          }
          if (
            options.has &&
            !options.has
              .resolve()
              .some((match) => element.contains(match) && match !== element)
          ) {
            return false;
          }
          if (
            options.hasNot &&
            options.has === undefined &&
            options.hasNot.resolve().some((match) => element.contains(match))
          ) {
            return false;
          }
          if (options.visible !== undefined && isVisible(element) !== options.visible) {
            return false;
          }
          return true;
        }),
      `${this.description} >> filter`
    );
  }

  and(other: Locator) {
    return new Locator((root) => {
      const others = new Set(other.query(root));
      return this.query(root).filter((element) => others.has(element));
    }, `${this.description} & ${other.description}`);
  }

  or(other: Locator) {
    return new Locator(
      (root) =>
        sortInDocumentOrder([...new Set([...this.query(root), ...other.query(root)])]),
      `${this.description} | ${other.description}`
    );
  }

  nth(index: number) {
    return new Locator((root) => {
      const all = this.query(root);
      const element = index < 0 ? all[all.length + index] : all[index];
      return element ? [element] : [];
    }, `${this.description} >> nth=${index}`);
  }

  first() {
    return this.nth(0);
  }

  last() {
    return this.nth(-1);
  }

  async count() {
    return this.resolve().length;
  }

  async all() {
    return this.resolve().map((_, index) => this.nth(index));
  }

  /** The single matching element, waiting until it exists. */
  async element(timeout = actionTimeout): Promise<HTMLElement> {
    const deadline = waitNow() + timeout;
    for (;;) {
      const matches = this.resolve();
      if (matches.length > 1) {
        throw new Error(
          `strict mode violation: ${this.description} resolved to ${matches.length} elements`
        );
      }
      if (matches[0]) return matches[0] as HTMLElement;
      if (waitNow() > deadline) {
        throw new Error(`Timed out waiting for ${this.description}`);
      }
      await waitNext();
    }
  }

  /** Pins the element matched now, as Playwright's ElementHandle does. */
  async elementHandle() {
    const element = await this.element();
    return new ElementHandle(
      () => (element.isConnected ? [element] : []),
      this.description
    );
  }

  async elementHandles() {
    return this.resolve().map(
      (element) =>
        new Locator(() => (element.isConnected ? [element] : []), this.description)
    );
  }

  async evaluate<R, A = undefined, E extends Element = HTMLElement>(
    fn: (element: E, arg: Unwrapped<A>) => R | Promise<R>,
    arg?: A
  ): Promise<R> {
    return evaluated(
      inPage(fn)((await this.element()) as unknown as E, unwrap(arg) as Unwrapped<A>)
    );
  }

  async evaluateAll<R, A = undefined, E extends Element = HTMLElement>(
    fn: (elements: E[], arg: Unwrapped<A>) => R | Promise<R>,
    arg?: A
  ): Promise<R> {
    return evaluated(
      inPage(fn)(this.resolve() as unknown as E[], unwrap(arg) as Unwrapped<A>)
    );
  }

  async evaluateHandle<R, A = undefined, E extends Element = HTMLElement>(
    fn: (element: E, arg: Unwrapped<A>) => R | Promise<R>,
    arg?: A
  ) {
    return handle(
      await inPage(fn)(
        (await this.element()) as unknown as E,
        unwrap(arg) as Unwrapped<A>
      )
    );
  }

  async boundingBox(): Promise<BoundingBox | null> {
    const element = this.resolve()[0];
    if (!element || !element.isConnected) return null;
    const rect = element.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  }

  async getAttribute(name: string) {
    return (await this.element()).getAttribute(name);
  }

  async textContent() {
    return (await this.element()).textContent;
  }

  async innerText() {
    return (await this.element()).innerText;
  }

  async inputValue() {
    return ((await this.element()) as HTMLInputElement).value;
  }

  async isVisible() {
    const element = this.resolve()[0];
    return element ? isVisible(element) : false;
  }

  async isChecked() {
    const element = await this.element();
    return (
      (element as HTMLInputElement).checked ??
      element.getAttribute("aria-checked") === "true"
    );
  }

  async waitFor(
    options: {
      state?: "attached" | "detached" | "visible" | "hidden";
      timeout?: number;
    } = {}
  ) {
    const state = options.state ?? "visible";
    await poll(
      () => {
        const element = this.resolve()[0];
        if (state === "attached") return Boolean(element);
        if (state === "detached") return !element;
        if (state === "visible") return Boolean(element && isVisible(element));
        return !element || !isVisible(element);
      },
      options.timeout ?? actionTimeout,
      `${this.description} to be ${state}`
    );
  }

  async scrollIntoViewIfNeeded() {
    scrollIntoViewIfNeeded(await this.actionable({ force: true }));
  }

  async focus() {
    (await this.element()).focus();
  }

  async blur() {
    (await this.element()).blur();
  }

  async dispatchEvent(type: string, init: Record<string, unknown> = {}) {
    const element = await this.element();
    element.dispatchEvent(createEvent(type, init));
  }

  async hover(options: ClickOptions = {}) {
    // Playwright hovers a disabled element: hover does not wait for it to be enabled.
    const point = await this.point({ ...options, enabled: false });
    await input.mouseMove(point.x, point.y);
  }

  async click(options: ClickOptions = {}) {
    const point = await this.point(options);
    // A trial only waits until the element could be clicked, as Playwright's.
    if (options.trial) return;
    await withModifiers(options.modifiers, async () => {
      await input.mouseMove(point.x, point.y);
      for (let click = 1; click <= (options.clickCount ?? 1); click += 1) {
        await input.mouseDown(options.button, click);
        if (options.delay) await stepFor(options.delay);
        await input.mouseUp(options.button, click);
      }
    });
  }

  async dblclick(options: ClickOptions = {}) {
    await this.click({ ...options, clickCount: 2 });
  }

  async tap(options: ClickOptions = {}) {
    const element = await this.actionable(options);
    const rect = element.getBoundingClientRect();
    const clientX = rect.x + (options.position?.x ?? rect.width / 2);
    const clientY = rect.y + (options.position?.y ?? rect.height / 2);
    const touch = new Touch({ identifier: 1, target: element, clientX, clientY });
    const init = { bubbles: true, cancelable: true, composed: true };
    for (const type of ["pointerdown", "pointerup"] as const) {
      element.dispatchEvent(
        new (win().PointerEvent)(type, {
          ...init,
          clientX,
          clientY,
          pointerType: "touch",
          isPrimary: true,
        })
      );
    }
    element.dispatchEvent(
      new (win().TouchEvent)("touchstart", {
        ...init,
        touches: [touch],
        changedTouches: [touch],
      })
    );
    element.dispatchEvent(
      new (win().TouchEvent)("touchend", { ...init, changedTouches: [touch] })
    );
    element.dispatchEvent(
      new (win().MouseEvent)("click", { ...init, clientX, clientY })
    );
  }

  async fill(value: string) {
    const element = (await this.actionable({})) as HTMLInputElement;
    element.focus();
    if (element.isContentEditable) {
      doc().execCommand("selectAll");
      if (value) doc().execCommand("insertText", false, value);
      else doc().execCommand("delete");
      return;
    }
    const setter = Object.getOwnPropertyDescriptor(
      Object.getPrototypeOf(element),
      "value"
    )?.set;
    setter?.call(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  async selectOption(
    values:
      | string
      | { label?: string; value?: string; index?: number }
      | (string | { label?: string; value?: string })[]
  ) {
    const select = (await this.actionable({})) as unknown as HTMLSelectElement;
    const wanted = Array.isArray(values) ? values : [values];
    const options = [...select.options];
    const chosen = wanted.map((item) => {
      const option =
        typeof item === "string"
          ? options.find(
              (candidate) => candidate.value === item || candidate.label === item
            )
          : options.find(
              (candidate, index) =>
                (item.value === undefined || candidate.value === item.value) &&
                (item.label === undefined || candidate.label === item.label) &&
                ((item as { index?: number }).index === undefined ||
                  index === (item as { index?: number }).index)
            );
      if (!option)
        throw new Error(`No option ${JSON.stringify(item)} in ${this.description}`);
      return option;
    });
    for (const option of options) option.selected = chosen.includes(option);
    select.dispatchEvent(new Event("input", { bubbles: true }));
    select.dispatchEvent(new Event("change", { bubbles: true }));
    return chosen.map((option) => option.value);
  }

  async press(key: string) {
    (await this.element()).focus();
    await input.keyboardPress(key);
  }

  async selectText() {
    const element = await this.element();
    const range = doc().createRange();
    range.selectNodeContents(element);
    const selection = win().getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
  }

  async screenshot() {
    return new Uint8Array();
  }

  /** Waits for Playwright's actionability checks, then scrolls into view. */
  async actionable(options: {
    force?: boolean;
    timeout?: number;
    /** Whether the action waits for the element to be enabled (not for a hover). */
    enabled?: boolean;
  }): Promise<HTMLElement> {
    let element = await this.element(options.timeout);
    if (options.force) return element;
    let previous = "";
    await poll(
      async () => {
        // A node the page replaced is not the one to act on: the locator
        // resolves again, as Playwright's does on each retry.
        if (!element.isConnected) {
          const matches = this.resolve();
          if (matches.length !== 1) return false;
          element = matches[0] as HTMLElement;
          previous = "";
        }
        if (!isVisible(element)) return false;
        if (options.enabled !== false && (element as HTMLButtonElement).disabled)
          return false;
        const rect = element.getBoundingClientRect();
        const current = `${rect.x},${rect.y},${rect.width},${rect.height}`;
        const stable = current === previous;
        previous = current;
        if (!stable) await waitStep();
        return stable;
      },
      options.timeout ?? actionTimeout,
      `${this.description} to be visible, enabled and stable`
    );
    return element;
  }

  private async point(options: ClickOptions) {
    const element = await this.actionable(options);
    const target = () => {
      const rect = element.getBoundingClientRect();
      return {
        x: rect.x + (options.position?.x ?? rect.width / 2),
        y: rect.y + (options.position?.y ?? rect.height / 2),
      };
    };
    // Like Playwright, bring the point that will be hit into view.
    const point = target();
    if (
      point.x < 0 ||
      point.y < 0 ||
      point.x >= win().innerWidth ||
      point.y >= win().innerHeight
    ) {
      element.scrollIntoView(
        options.position
          ? { block: "start", inline: "start" }
          : { block: "center", inline: "center" }
      );
    }
    if (options.force) return target();
    // Like Playwright, wait until the point hits the element itself, not a
    // control still moving into place or an overlay above it.
    let hit = target();
    let top: Element | null = null;
    // An element under another one is scrolled to the end, the centre and the
    // start of its scroller in turn, as Playwright retries an obstructed action.
    const alignments: ScrollLogicalPosition[] = ["end", "center", "start"];
    let attempts = 0;
    try {
      await poll(
        async () => {
          hit = target();
          top = deepElementFromPoint(hit.x, hit.y);
          if (top && (top === element || element.contains(top))) return true;
          if (!options.position) {
            const block = alignments[attempts % alignments.length]!;
            element.scrollIntoView({ block, inline: block });
          }
          attempts += 1;
          await waitStep();
          return false;
        },
        options.timeout ?? actionTimeout,
        `${this.description} to receive pointer events`
      );
    } catch (error) {
      const at = `(${Math.round(hit.x)}, ${Math.round(hit.y)})`;
      const receiver = top ? describeElement(top) : "nothing";
      throw new Error(
        `${(error as Error).message}: ${receiver} receives them at ${at}`,
        { cause: error }
      );
    }
    return hit;
  }
}

// elementFromPoint stops at a shadow host; follow open shadow roots down.
function deepElementFromPoint(x: number, y: number) {
  let top = doc().elementFromPoint(x, y);
  while (top?.shadowRoot) {
    const inner = top.shadowRoot.elementFromPoint(x, y);
    if (!inner || inner === top) break;
    top = inner;
  }
  return top;
}

type FilterOptions = {
  has?: Locator;
  hasNot?: Locator;
  hasText?: TextMatcher;
  hasNotText?: TextMatcher;
  visible?: boolean;
};

type RoleOptions = {
  name?: TextMatcher;
  exact?: boolean;
  checked?: boolean;
  disabled?: boolean;
  expanded?: boolean;
  includeHidden?: boolean;
  level?: number;
  pressed?: boolean;
  selected?: boolean;
};

function byRole(root: Element, role: string, options: RoleOptions) {
  const query: ByRoleOptions = { hidden: options.includeHidden ?? false };
  if (options.checked !== undefined) query.checked = options.checked;
  if (options.expanded !== undefined) query.expanded = options.expanded;
  if (options.level !== undefined) query.level = options.level;
  if (options.pressed !== undefined) query.pressed = options.pressed;
  if (options.selected !== undefined) query.selected = options.selected;
  if (options.name !== undefined) {
    const name = options.name;
    query.name = (accessibleName: string) =>
      matchesText(accessibleName, name, options.exact);
  }
  // Playwright's role query pierces open shadow roots.
  const matches = [root as ParentNode, ...shadowRoots(root)].flatMap((scope) =>
    queryAllByRole(scope as HTMLElement, role, query)
  );
  return options.disabled === undefined
    ? matches
    : matches.filter(
        (element) =>
          ((element as HTMLButtonElement).disabled ||
            element.getAttribute("aria-disabled") === "true") === options.disabled
      );
}

function byText(root: Element, text: TextMatcher, exact = false) {
  return queryAllByText(
    root as HTMLElement,
    (_content, element) =>
      Boolean(element) &&
      matchesText(element!.textContent ?? "", text, exact) &&
      ![...element!.children].some((child) =>
        matchesText(child.textContent ?? "", text, exact)
      ),
    { ignore: "script, style" }
  );
}

function byLabel(root: Element, text: TextMatcher, exact = false) {
  const labelled = queryAllByLabelText(
    root as HTMLElement,
    (content) => matchesText(content, text, exact),
    { selector: "*" }
  );
  const ariaLabelled = [...root.querySelectorAll("[aria-label]")].filter((element) =>
    matchesText(element.getAttribute("aria-label") ?? "", text, exact)
  );
  return sortInDocumentOrder([...new Set([...labelled, ...ariaLabelled])]);
}

/** Matches in the root and every open shadow root below it, as Playwright does. */
/** The open shadow roots under `root`, at any depth. */
function shadowRoots(root: ParentNode): ShadowRoot[] {
  const found: ShadowRoot[] = [];
  const walker = doc().createTreeWalker(root as Node, win().NodeFilter.SHOW_ELEMENT);
  for (
    let node = walker.currentNode as Element | null;
    node;
    node = walker.nextNode() as Element | null
  ) {
    if (node.shadowRoot) found.push(node.shadowRoot, ...shadowRoots(node.shadowRoot));
  }
  return found;
}

function deepQueryAll(root: ParentNode, selector: string): Element[] {
  // Playwright's `:visible` keeps the visible matches of what precedes it.
  if (selector.endsWith(":visible"))
    return deepQueryAll(root, selector.slice(0, -":visible".length)).filter(isVisible);
  const result = [...root.querySelectorAll(selector)];
  const walker = doc().createTreeWalker(root as Node, win().NodeFilter.SHOW_ELEMENT);
  for (
    let node = walker.currentNode as Element | null;
    node;
    node = walker.nextNode() as Element | null
  ) {
    if (node.shadowRoot) result.push(...deepQueryAll(node.shadowRoot, selector));
  }
  return result;
}

function selectAll(root: Element, selector: string): Element[] {
  // The nearest ancestor with an attribute value (`[1]`, or the first of
  // them, is the nearest either way for the uses here).
  const ancestor =
    /^xpath=ancestor::\*\[@([\w-]+)=(?:'([^']+)'|"([^"]+)")\](?:\[1\])?$/.exec(
      selector
    );
  if (ancestor) {
    const match = root.parentElement?.closest(
      `[${ancestor[1]}="${ancestor[2] ?? ancestor[3]}"]`
    );
    return match ? [match] : [];
  }
  const classAncestor = /^xpath=ancestor::\*\[contains\(@class, '([^']+)'\)\]$/.exec(
    selector
  );
  if (classAncestor) {
    const ancestors: Element[] = [];
    for (let node = root.parentElement; node; node = node.parentElement) {
      if ((node.getAttribute("class") ?? "").includes(classAncestor[1]!))
        ancestors.push(node);
    }
    return ancestors.toReversed();
  }
  const tagAncestor = /^xpath=ancestor::([a-z][\w-]*)$/.exec(selector);
  if (tagAncestor) {
    const ancestors: Element[] = [];
    for (let node = root.parentElement; node; node = node.parentElement) {
      if (node.localName === tagAncestor[1]) ancestors.push(node);
    }
    return ancestors.toReversed();
  }
  if (selector === "..") return root.parentElement ? [root.parentElement] : [];
  return deepQueryAll(root, selector);
}

function sortInDocumentOrder(elements: Element[]) {
  return elements.toSorted((a, b) =>
    a === b
      ? 0
      : a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING
        ? -1
        : 1
  );
}

function scrollIntoViewIfNeeded(element: Element) {
  const rect = element.getBoundingClientRect();
  if (
    rect.top < 0 ||
    rect.left < 0 ||
    rect.bottom > win().innerHeight ||
    rect.right > win().innerWidth
  ) {
    element.scrollIntoView({ block: "center", inline: "center" });
  }
}

function createEvent(type: string, init: Record<string, unknown>) {
  const options = { bubbles: true, cancelable: true, composed: true, ...init };
  if (type.startsWith("pointer")) return new (win().PointerEvent)(type, options);
  if (/^(click|dblclick|mouse|contextmenu)/.test(type))
    return new (win().MouseEvent)(type, options);
  if (type.startsWith("key")) return new (win().KeyboardEvent)(type, options);
  if (type.startsWith("focus") || type === "blur")
    return new (win().FocusEvent)(type, options);
  if (type === "wheel") return new (win().WheelEvent)(type, options);
  if (type.startsWith("drag") || type === "drop")
    return new (win().DragEvent)(type, options);
  return new Event(type, options);
}

async function withModifiers(
  modifiers: string[] | undefined,
  action: () => Promise<void>
) {
  const keys = (modifiers ?? []).map((key) => (key === "ControlOrMeta" ? "Meta" : key));
  for (const key of keys) await input.keyboardDown(key);
  try {
    await action();
  } finally {
    for (const key of keys.toReversed()) await input.keyboardUp(key);
  }
}

async function poll(
  check: () => boolean | Promise<boolean>,
  timeout: number,
  description: string
) {
  const deadline = waitNow() + timeout;
  for (;;) {
    if (await check()) return;
    if (waitNow() > deadline) throw new Error(`Timed out waiting for ${description}`);
    await waitNext();
  }
}

/** An evaluate argument as the page receives it: handles become elements. */
export type Unwrapped<T> = T extends Locator
  ? HTMLElement
  : T extends (...args: never[]) => unknown
    ? T
    : T extends readonly unknown[]
      ? { [K in keyof T]: Unwrapped<T[K]> }
      : T extends object
        ? { [K in keyof T]: Unwrapped<T[K]> }
        : T;

/** Element handles passed as evaluate arguments arrive as their elements. */
/**
 * One element as Playwright's ElementHandle holds it: a locator of that
 * element while it is attached, and a value of its own to an assertion
 * (`expect(handle).not.toBeNull()`).
 */
class ElementHandle extends Locator {
  /** Only in its type: `expect` tells a handle from a locator by it. */
  declare readonly handleOfElement: true;
}

function unwrap<T>(value: T): T {
  if (value instanceof Locator) return value.resolve()[0] as T;
  if (Array.isArray(value)) return value.map(unwrap) as T;
  if (
    value &&
    typeof value === "object" &&
    Object.getPrototypeOf(value) === Object.prototype
  ) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, unwrap(item)])
    ) as T;
  }
  return value;
}

/** A value kept in the page, as Playwright's JSHandle is. */
function handle<T>(value: T) {
  return {
    async evaluate<R, A = undefined>(
      fn: (value: T, arg: A) => R | Promise<R>,
      arg?: A
    ) {
      return evaluated(inPage(fn)(value, arg as A));
    },
    async jsonValue() {
      return value;
    },
    async dispose() {},
  };
}

type CdpPayload = { value: Record<string, unknown>[] };

function createCdpSession() {
  const listeners = new Map<string, ((payload: CdpPayload) => void)[]>();
  const emit = (event: string, payload: CdpPayload) => {
    for (const listener of listeners.get(event) ?? []) listener(payload);
  };
  return {
    on(event: string, listener: (payload: CdpPayload) => void) {
      listeners.set(event, [...(listeners.get(event) ?? []), listener]);
    },
    once(event: string, listener: (payload: CdpPayload) => void) {
      const wrapped = (payload: CdpPayload) => {
        listeners.set(
          event,
          (listeners.get(event) ?? []).filter((item) => item !== wrapped)
        );
        listener(payload);
      };
      this.on(event, wrapped);
    },
    async send(method: string, params?: Record<string, unknown>) {
      const result = await commands.cdpSend(method, params);
      if (method === "Tracing.end") {
        emit("Tracing.dataCollected", {
          value: (result as { events: Record<string, unknown>[] }).events,
        });
        emit("Tracing.tracingComplete", { value: [] });
        return {};
      }
      return result as never;
    },
    async detach() {},
  };
}

// --- page --------------------------------------------------------------------

type Mount = (url: URL) => void | Promise<void>;

const documentLocator = new Locator((root) => [root as unknown as Element], "document");
const viewport = { width: 1280, height: 800 };
// The size the frame was last given, unknown until the first test gives one.
let appliedViewport: string | undefined;

/**
 * Takes a fixture's mount function. `goto(url)` replaces the previous fixture
 * and mounts a fresh one for the URL's query, standing in for a page load.
 */
export function createPage(mount: Mount) {
  const initScripts: (() => unknown)[] = [];
  let currentUrl = "about:blank";
  let reloadStorage:
    | { local: Record<string, string>; session: Record<string, string> }
    | undefined;
  async function gotoPage(url: string, { reload = false }: { reload?: boolean } = {}) {
    // A navigation loads a new document: a second goto in a test opens a
    // new page, as the first one was; a reload loads it in the same frame.
    if (pageMounted) {
      testRequests.push(...testPage().resources().slice(mountedRequests));
      // The tab's storage stays with it, as the browser keeps the origin's.
      const view = win();
      reloadStorage = {
        local: storageEntries(view.localStorage),
        session: storageEntries(view.sessionStorage),
      };
      await (reload ? reloadTestPage() : reopenTestPage());
      // The new page has the focus, as the test's first page had.
      await commands.focusFrame();
      win().focus();
    }
    pageMounted = true;
    if (fakeMediaSources) testPage().fakeMedia(fakeMediaSources);
    // Before the fixture loads: the workers it starts are realms from the start.
    // The requests it makes as it loads are the world's from the first; a
    // warm-up's page has no server to ask.
    if (pageWorld) await openPageWorld(warmingUp ? [] : (pageServers?.() ?? []));
    // A new page's pointer is where the test left it (./hover).
    if (lastPointer) testPage().setPointer(lastPointer);
    if (pageInit) inPage(pageInit)();
    // The next page of the tab starts with the storage the page before left.
    if (reloadStorage) {
      for (const [key, value] of Object.entries(reloadStorage.local))
        win().localStorage.setItem(key, value);
      for (const [key, value] of Object.entries(reloadStorage.session))
        win().sessionStorage.setItem(key, value);
      reloadStorage = undefined;
    }
    for (const script of initScripts) await script();
    const resolved = new URL(url, "http://fixture.test/");
    currentUrl = resolved.href;
    await mount(resolved);
    if (pageWorld) await pageMountedInWorld();
    // The modules the fixture loads lazily load now; their styles may add
    // font faces.
    for (const module of lazyModules)
      await (win() as unknown as { eval(code: string): Promise<unknown> }).eval(
        `import(${JSON.stringify(module)})`
      );
    // Every font face loads before the test measures: a face that a later
    // render first asks for would load on real time and move the layout
    // under the test.
    await Promise.allSettled(Array.from(doc().fonts, (face) => face.load()));
    // Loading ends with the mount, page time standing still: images decoded
    // and no request in flight. The test itself makes none (./record).
    await Promise.allSettled(Array.from(doc().images, (image) => image.decode()));
    // Where the page's mount ends on its own request timeline: what it
    // requests after that, the test requested.
    const loaded = testPage().resources();
    for (const request of loaded) {
      if (isImage(request)) loadedImages.add(urlOf(request));
      // Every module a warm-up loads, its mount's included, each later page
      // loads with its fixture: what a mount loads may depend on how far
      // its first render got.
      if (warmingUp && isPageModule(request)) lazyModules.add(urlOf(request));
      if (warmingUp && isWorkerEntry(request))
        warmWorkers.add(withoutFragment(urlOf(request)));
    }
    mountedRequests = loaded.length;
  }
  const page = {
    goto(url: string) {
      return timed("mount", () => gotoPage(url));
    },
    url: () => (pageOwnsUrl && pageMounted ? win().location.href : currentUrl),
    /**
     * The page's history goes back an entry, as Playwright's goBack: the
     * browser's traversal (a task of its own) has reached the page before
     * page time moves on.
     */
    async goBack() {
      const view = win();
      const traversed = new Promise<void>((resolve) =>
        view.addEventListener("popstate", () => resolve(), { once: true })
      );
      view.history.back();
      await traversed;
      await waitStep();
    },
    /** The page's next download or popup (nextDownload, nextPopup). */
    waitForEvent: ((event: "download" | "popup" | "filechooser") => {
      if (event === "popup") return nextPopup();
      if (event === "download") return nextDownload();
      if (event === "filechooser") return nextFileChooser();
      throw new Error(`waitForEvent(${String(event)}) is not supported`);
    }) as {
      (event: "download"): ReturnType<typeof nextDownload>;
      (event: "popup"): ReturnType<typeof nextPopup>;
      (event: "filechooser"): ReturnType<typeof nextFileChooser>;
    },
    async screenshot(options: { clip: BoundingBox }) {
      const data = await commands.screenshot(options.clip);
      return { toString: () => data };
    },
    resetInitScripts() {
      initScripts.length = 0;
    },
    /** Runs now and before every later mount, like a page's init script. */
    async addInitScript<A>(script: (arg: A) => unknown, arg?: A) {
      initScripts.push(() => inPage(script)(arg as A));
      await script(arg as A);
    },
    /**
     * The page's document loads again at its URL, as Playwright's reload: a
     * new page, with the storage the page left.
     */
    async reload() {
      // The document the frame shows now: the app routes in its fragment.
      const { hash } = win().location;
      await gotoPage(new URL(hash, currentUrl).href, { reload: true });
    },
    /** A frame of the page, of another origin: its locators read through CDP (./frames). */
    frameLocator(selector: string) {
      const frames = documentLocator.locator(selector);
      return new FrameLocator(() => {
        const found = frames.resolve();
        if (found.length !== 1 || !(found[0] instanceof win().HTMLIFrameElement))
          throw new Error(`${selector} matches ${found.length} frames`);
        return found[0] as HTMLIFrameElement;
      }, page);
    },
    locator: (selector: string, options?: FilterOptions) =>
      new Locator((root) => deepQueryAll(root as Document, selector), selector).filter(
        options ?? {}
      ),
    getByRole: (role: string, options?: RoleOptions) =>
      new Locator(() => byRole(doc().body, role, options ?? {}), `role=${role}`),
    getByTestId: (id: string | RegExp) => documentLocator.getByTestId(id),
    getByText: (text: TextMatcher, options?: { exact?: boolean }) =>
      new Locator(() => byText(doc().body, text, options?.exact), `text=${text}`),
    getByLabel: (text: TextMatcher, options?: { exact?: boolean }) =>
      new Locator(() => byLabel(doc().body, text, options?.exact), `label=${text}`),
    getByPlaceholder: (text: TextMatcher, options?: { exact?: boolean }) =>
      documentLocator.getByPlaceholder(text, options),
    async evaluate<R, A = undefined>(
      fn: (arg: Unwrapped<A>) => R | Promise<R>,
      arg?: A
    ): Promise<R> {
      return evaluated(inPage(fn)(unwrap(arg) as Unwrapped<A>));
    },
    async waitForFunction<R, A = undefined>(
      fn: (arg: A) => R | Promise<R>,
      arg?: A,
      options: { timeout?: number; polling?: number | "raf" } = {}
    ): Promise<R> {
      const deadline = waitNow() + (options.timeout ?? actionTimeout);
      for (;;) {
        const value = await inPage(fn)(arg as A);
        if (value) return value;
        if (waitNow() > deadline) throw new Error("waitForFunction timed out");
        if (options.polling === "raf" || options.polling === undefined)
          await waitStep();
        else await stepFor(options.polling);
      }
    },
    async evaluateHandle<R, A = undefined>(fn: (arg: A) => R | Promise<R>, arg?: A) {
      return handle(await evaluated(inPage(fn)(arg as A)));
    },
    context: () => ({
      newCDPSession: async (_page?: unknown) => createCdpSession(),
      grantPermissions: (permissions: string[], _options?: { origin?: string }) =>
        commands.grantPermissions(permissions),
    }),
    async waitForTimeout(ms: number) {
      await stepFor(ms);
    },
    async setViewportSize(size: { width: number; height: number }) {
      viewport.width = size.width;
      viewport.height = size.height;
      // The frame keeps its size between tests: only a change resizes it.
      const key = `${size.width}x${size.height}`;
      if (appliedViewport === key) return;
      await sendInput("viewport", [size.width, size.height], () =>
        browserPage.viewport(size.width, size.height)
      );
      appliedViewport = key;
    },
    viewportSize: () => ({ ...viewport }),
    async emulateMedia(options: Record<string, unknown>) {
      await sendInput("emulateMedia", [options], () => commands.emulateMedia(options));
    },
    async addStyleTag(options: { content: string }) {
      const style = doc().createElement("style");
      style.textContent = options.content;
      style.dataset.testStyle = "";
      doc().head.append(style);
      return handle(style);
    },
    async bringToFront() {},
    mouse: {
      move: (x: number, y: number, options: { steps?: number } = {}) =>
        input.mouseMove(x, y, options.steps),
      down: (options: { button?: "left" | "right" | "middle" } = {}) =>
        input.mouseDown(options.button),
      up: (options: { button?: "left" | "right" | "middle" } = {}) =>
        input.mouseUp(options.button),
      wheel: (deltaX: number, deltaY: number) => input.mouseWheel(deltaX, deltaY),
      async click(
        x: number,
        y: number,
        options: { button?: "left" | "right" | "middle"; clickCount?: number } = {}
      ) {
        await input.mouseMove(x, y);
        for (let click = 1; click <= (options.clickCount ?? 1); click += 1) {
          await input.mouseDown(options.button, click);
          await input.mouseUp(options.button, click);
        }
      },
    },
    keyboard: {
      press: (key: string, options: { delay?: number } = {}) =>
        input.keyboardPress(key, options.delay),
      down: (key: string) => input.keyboardDown(key),
      up: (key: string) => input.keyboardUp(key),
      type: (text: string, options: { delay?: number } = {}) =>
        input.keyboardType(text, options.delay),
      insertText: (text: string) => input.keyboardInsertText(text),
    },
  };
  pages.add(page);
  return page;
}

// The pages `createPage` made: what `expect(page)` asserts of.
const pages = new WeakSet<object>();

export type Page = ReturnType<typeof createPage>;

// --- assertions --------------------------------------------------------------

type MatcherOptions = { timeout?: number };

/** The one element a single-element assertion is about. */
const single = (elements: Element[]) => {
  if (elements.length > 1) throw new Error("strict mode violation");
  return elements[0] as HTMLElement | undefined;
};
const text = (element: Element) =>
  normalize((element as HTMLElement).innerText ?? element.textContent ?? "");
// What Playwright's text assertions read: the text content, unless the
// assertion asks for the rendered text.
const assertedText = (element: Element, innerText = false) =>
  innerText ? text(element) : normalize(element.textContent ?? "");

const describeElement = (element: Element) => {
  const label = element.getAttribute("aria-label");
  return `${element.localName}${element.id ? `#${element.id}` : ""}${[
    ...element.classList,
  ]
    .slice(0, 2)
    .map((name) => `.${name}`)
    .join("")}${label ? `[aria-label="${label}"]` : ""}`;
};

// Hover, focus and pointer state at a failure: CSS-state assertions fail
// for a pointer in the wrong place far more often than for the style itself.
async function interactionState() {
  const hovered = [...doc().querySelectorAll(":hover")].map(describeElement);
  const focused = doc().activeElement;
  const active = focused ? describeElement(focused) : "none";
  const media = ["(hover: hover)", "(pointer: fine)", "(any-pointer: coarse)"]
    .map((query) => `${query}=${win().matchMedia(query).matches}`)
    .join(" ");
  const pointer = await commands.pointerState().catch(() => "unavailable");
  return `\n  hover: ${hovered.join(" > ") || "none"}\n  focus: ${active}\n  media: ${media}\n  pointer: ${JSON.stringify(pointer)}`;
}

function locatorMatchers(locator: Locator, negate: boolean, soft = false) {
  const assert = async (
    check: (elements: Element[]) => boolean,
    description: string,
    options: MatcherOptions = {},
    actual: () => unknown = () => locator.resolve().length
  ) => {
    const deadline = waitNow() + (options.timeout ?? defaultTimeout);
    for (;;) {
      let passed = false;
      try {
        passed = check(locator.resolve()) !== negate;
      } catch {
        passed = false;
      }
      if (passed) return;
      if (waitNow() > deadline) {
        let received: unknown;
        try {
          received = actual();
        } catch (error) {
          received = error;
        }
        const message = `expect(${locator.description}).${negate ? "not." : ""}${description} failed; received ${JSON.stringify(received)}${await interactionState()}`;
        if (soft) {
          baseExpect.soft(message).toBe("");
          return;
        }
        throw new Error(message);
      }
      await waitNext();
    }
  };
  const matchers = {
    toBeVisible: (options?: MatcherOptions & { visible?: boolean }) =>
      assert(
        (elements) => {
          const element = single(elements);
          const visible = Boolean(element && isVisible(element));
          return options?.visible === false ? !visible : visible;
        },
        "toBeVisible()",
        options
      ),
    toBeHidden: (options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          return !element || !isVisible(element);
        },
        "toBeHidden()",
        options
      ),
    toBeAttached: (options?: MatcherOptions & { attached?: boolean }) =>
      assert(
        (elements) =>
          options?.attached === false ? elements.length === 0 : elements.length === 1,
        "toBeAttached()",
        options
      ),
    toBeInViewport: (options?: MatcherOptions & { ratio?: number }) =>
      assert(
        (elements) => {
          const element = single(elements);
          if (!element) return false;
          const rect = element.getBoundingClientRect();
          const width = Math.min(rect.right, win().innerWidth) - Math.max(rect.left, 0);
          const height =
            Math.min(rect.bottom, win().innerHeight) - Math.max(rect.top, 0);
          const ratio =
            width > 0 && height > 0 ? (width * height) / (rect.width * rect.height) : 0;
          return options?.ratio === undefined ? ratio > 0 : ratio >= options.ratio;
        },
        "toBeInViewport()",
        options
      ),
    toBeFocused: (options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          return Boolean(element) && doc().activeElement === element;
        },
        "toBeFocused()",
        options,
        () => doc().activeElement?.outerHTML.slice(0, 120)
      ),
    toBeDisabled: (options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          return Boolean(
            element &&
            ((element as HTMLButtonElement).disabled ||
              element.getAttribute("aria-disabled") === "true")
          );
        },
        "toBeDisabled()",
        options
      ),
    toBeEnabled: (options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          return Boolean(
            element &&
            !(element as HTMLButtonElement).disabled &&
            element.getAttribute("aria-disabled") !== "true"
          );
        },
        "toBeEnabled()",
        options
      ),
    toBeEditable: (options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements) as HTMLInputElement | undefined;
          if (!element) return false;
          if (element.isContentEditable)
            return element.getAttribute("aria-readonly") !== "true";
          return (
            ["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) &&
            !element.disabled &&
            !element.readOnly &&
            element.getAttribute("aria-disabled") !== "true"
          );
        },
        "toBeEditable()",
        options
      ),
    toBeChecked: (options?: MatcherOptions & { checked?: boolean }) =>
      assert(
        (elements) => {
          const element = single(elements);
          if (!element) return false;
          const checked =
            (element as HTMLInputElement).checked === true ||
            element.getAttribute("aria-checked") === "true";
          return options?.checked === false ? !checked : checked;
        },
        "toBeChecked()",
        options
      ),
    toHaveCount: (count: number, options?: MatcherOptions) =>
      assert((elements) => elements.length === count, `toHaveCount(${count})`, options),
    toHaveAttribute: (
      name: string,
      value?: TextMatcher | MatcherOptions,
      options?: MatcherOptions
    ) => {
      const expected =
        typeof value === "string" || value instanceof RegExp ? value : undefined;
      const settings =
        expected === undefined &&
        value &&
        typeof value === "object" &&
        !(value instanceof RegExp)
          ? value
          : options;
      return assert(
        (elements) => {
          const attribute = single(elements)?.getAttribute(name);
          if (attribute === null || attribute === undefined) return false;
          if (expected === undefined) return true;
          return typeof expected === "string"
            ? attribute === expected
            : expected.test(attribute);
        },
        `toHaveAttribute(${name}, ${String(expected)})`,
        settings,
        () => single(locator.resolve())?.getAttribute(name)
      );
    },
    toHaveCSS: (name: string, value: TextMatcher, options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          if (!element) return false;
          const actual = win().getComputedStyle(element).getPropertyValue(name);
          return typeof value === "string" ? actual === value : value.test(actual);
        },
        `toHaveCSS(${name}, ${String(value)})`,
        options,
        () => {
          const element = single(locator.resolve());
          return element
            ? win().getComputedStyle(element).getPropertyValue(name)
            : null;
        }
      ),
    toHaveClass: (value: TextMatcher | TextMatcher[], options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          if (!element) return false;
          const className = element.getAttribute("class") ?? "";
          if (Array.isArray(value)) return false;
          return typeof value === "string"
            ? normalize(className) === normalize(value)
            : value.test(className);
        },
        `toHaveClass(${String(value)})`,
        options,
        () => single(locator.resolve())?.getAttribute("class")
      ),
    toHaveText: (
      value: TextMatcher | TextMatcher[],
      options?: MatcherOptions & { useInnerText?: boolean }
    ) =>
      assert(
        (elements) => {
          if (Array.isArray(value)) {
            return (
              elements.length === value.length &&
              elements.every((element, index) =>
                matchesText(
                  assertedText(element, options?.useInnerText),
                  value[index]!,
                  true
                )
              )
            );
          }
          const element = single(elements);
          return (
            Boolean(element) &&
            matchesText(assertedText(element!, options?.useInnerText), value, true)
          );
        },
        `toHaveText(${String(value)})`,
        options,
        () =>
          locator
            .resolve()
            .map((element) => assertedText(element, options?.useInnerText))
      ),
    toContainText: (value: TextMatcher | TextMatcher[], options?: MatcherOptions) =>
      assert(
        (elements) => {
          if (Array.isArray(value)) {
            let index = 0;
            for (const element of elements) {
              if (
                index < value.length &&
                matchesText(text(element), value[index]!, false)
              )
                index += 1;
            }
            return index === value.length;
          }
          const element = single(elements);
          return Boolean(element) && matchesText(text(element!), value, false);
        },
        `toContainText(${String(value)})`,
        options,
        () => locator.resolve().map(text)
      ),
    toHaveValue: (value: TextMatcher, options?: MatcherOptions) =>
      assert(
        (elements) => {
          const actual = (single(elements) as HTMLInputElement | undefined)?.value;
          return (
            actual !== undefined &&
            (typeof value === "string" ? actual === value : value.test(actual))
          );
        },
        `toHaveValue(${String(value)})`,
        options
      ),
    toHaveJSProperty: (name: string, value: unknown, options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements) as unknown as
            | Record<string, unknown>
            | undefined;
          return Boolean(element) && Object.is(element![name], value);
        },
        `toHaveJSProperty(${name})`,
        options
      ),
    toHaveAccessibleName: (value: TextMatcher, options?: MatcherOptions) =>
      assert(
        (elements) => {
          const element = single(elements);
          if (!element) return false;
          const role = element.getAttribute("role") ?? "";
          const named = byRole(
            element.parentElement ?? doc().body,
            role || element.tagName.toLowerCase(),
            {
              name: value,
              exact: true,
              includeHidden: true,
            }
          );
          return (
            named.includes(element) ||
            matchesText(element.getAttribute("aria-label") ?? "", value, true)
          );
        },
        `toHaveAccessibleName(${String(value)})`,
        options
      ),
  };
  return matchers;
}

type LocatorMatchers = ReturnType<typeof locatorMatchers>;
type LocatorExpect = LocatorMatchers & { not: LocatorMatchers };

/**
 * `expect(page)`: what the page's own document shows, waited for on page
 * time as a locator's assertion is.
 */
/**
 * A download the page asks for from now on (./requests): awaiting it
 * steps the test clock until the page has asked. The page starts it on
 * page time (after a delay, a retry); nothing else moves page time while
 * the test waits.
 */
type ChosenFile = { name: string; mimeType: string; buffer: Uint8Array | string };

// The file inputs whose chooser the page opened, by page: a chooser opens on
// no dialog, the test answers it (Playwright's FileChooser).
const fileChoosers = new WeakMap<Document, HTMLInputElement[]>();
function watchFileChoosers(view: Window & typeof globalThis) {
  if (fileChoosers.has(view.document)) return fileChoosers.get(view.document)!;
  const opened: HTMLInputElement[] = [];
  fileChoosers.set(view.document, opened);
  const proto = view.HTMLInputElement.prototype;
  const click = proto.click;
  const showPicker = proto.showPicker;
  proto.click = function (this: HTMLInputElement) {
    if (this.type === "file") opened.push(this);
    else click.call(this);
  };
  proto.showPicker = function (this: HTMLInputElement) {
    if (this.type === "file") opened.push(this);
    else showPicker.call(this);
  };
  return opened;
}

/** The page's next file chooser: the test sets its files, or none to cancel it. */
function nextFileChooser() {
  const view = win();
  const opened = watchFileChoosers(view);
  const before = opened.length;
  return {
    // oxlint-disable-next-line unicorn/no-thenable -- awaiting it is what steps the clock, not creating it.
    then<R1, R2 = never>(
      onSettled: (value: {
        setFiles(files: ChosenFile | ChosenFile[]): Promise<void>;
      }) => R1 | PromiseLike<R1>,
      onFailed?: (error: unknown) => R2 | PromiseLike<R2>
    ) {
      return stepUntil(() => opened.length > before, {
        description: "a file chooser of the page",
      })
        .then(() => {
          const field = opened[before]!;
          return {
            async setFiles(files: ChosenFile | ChosenFile[]) {
              const chosen = Array.isArray(files) ? files : [files];
              if (chosen.length === 0) {
                field.dispatchEvent(new view.Event("cancel", { bubbles: true }));
                return;
              }
              const transfer = new view.DataTransfer();
              for (const file of chosen)
                transfer.items.add(
                  new view.File([file.buffer as BlobPart], file.name, {
                    type: file.mimeType,
                  })
                );
              field.files = transfer.files;
              field.dispatchEvent(new view.Event("input", { bubbles: true }));
              field.dispatchEvent(new view.Event("change", { bubbles: true }));
            },
          };
        })
        .then(onSettled, onFailed);
    },
  };
}

function nextDownload() {
  const before = testPage().downloads().length;
  return {
    // oxlint-disable-next-line unicorn/no-thenable -- awaiting it is what steps the clock, not creating it.
    then<R1, R2 = never>(
      onSettled: (value: {
        suggestedFilename(): string;
        url(): string;
      }) => R1 | PromiseLike<R1>,
      onFailed?: (error: unknown) => R2 | PromiseLike<R2>
    ) {
      return stepUntil(() => testPage().downloads().length > before, {
        description: "a download of the page",
      })
        .then(() => {
          const download = testPage().downloads()[before]!;
          return {
            suggestedFilename: () => download.suggestedFilename,
            url: () => download.url,
          };
        })
        .then(onSettled, onFailed);
    },
  };
}

/**
 * A popup the page opens from now on (./requests, keepPopups): awaiting it
 * steps the test clock until the page has opened one. The popup is its URL:
 * it loads nothing, and closing it does nothing.
 */
function nextPopup() {
  const before = testPage().popups().length;
  return {
    // oxlint-disable-next-line unicorn/no-thenable -- awaiting it is what steps the clock, not creating it.
    then<R1, R2 = never>(
      onSettled: (value: PopupPage) => R1 | PromiseLike<R1>,
      onFailed?: (error: unknown) => R2 | PromiseLike<R2>
    ) {
      return stepUntil(() => testPage().popups().length > before, {
        description: "a popup of the page",
      })
        .then(() => {
          const { url } = testPage().popups()[before]!;
          const popup: PopupPage = { url: () => url, close: async () => {} };
          popupPages.add(popup);
          return popup;
        })
        .then(onSettled, onFailed);
    },
  };
}

type PopupPage = { url(): string; close(): Promise<void> };
const popupPages = new WeakSet<object>();

function expectPage(href: () => string) {
  const matchers = (negate: boolean) => ({
    async toHaveURL(expected: string | RegExp) {
      const matches = () => {
        const current = href();
        const match =
          typeof expected === "string" ? current === expected : expected.test(current);
        return match !== negate;
      };
      await stepUntil(matches, {
        description: `the page's URL ${negate ? "not " : ""}${String(expected)}`,
      });
    },
  });
  return { ...matchers(false), not: matchers(true) };
}

function expectLocator(locator: Locator, soft = false): LocatorExpect {
  return Object.assign(locatorMatchers(locator, false, soft), {
    not: locatorMatchers(locator, true, soft),
  });
}

type PageExpect = ReturnType<typeof expectPage>;
// What `expect` offers for `actual`: a value of type `any`, and an element
// handle, get the plain assertions.
type ExpectOf<T> = 0 extends 1 & T
  ? Assertion<T>
  : T extends ElementHandle
    ? Assertion<T>
    : T extends FrameElementLocator
      ? ReturnType<typeof expectFrameLocator>
      : T extends Locator
        ? LocatorExpect
        : T extends ReturnType<typeof createPage> | PopupPage
          ? PageExpect
          : Assertion<T>;

type CompatExpect = Omit<typeof baseExpect, "soft"> & {
  <T>(actual: T, message?: string): ExpectOf<T>;
  soft: <T>(
    actual: T,
    message?: string
  ) => T extends Locator ? LocatorExpect : Assertion<T>;
};

export const expect = Object.assign(
  (actual: unknown, message?: string) =>
    actual instanceof Locator && !(actual instanceof ElementHandle)
      ? expectLocator(actual)
      : actual instanceof FrameElementLocator
        ? expectFrameLocator(actual)
        : typeof actual === "object" && actual !== null && pages.has(actual)
          ? expectPage(() => win().location.href)
          : typeof actual === "object" && actual !== null && popupPages.has(actual)
            ? expectPage(() => (actual as PopupPage).url())
            : baseExpect(actual, message),
  baseExpect,
  {
    soft: (actual: unknown, message?: string) =>
      actual instanceof Locator && !(actual instanceof ElementHandle)
        ? expectLocator(actual, true)
        : baseExpect.soft(actual, message),
    poll: <T>(fn: () => T | Promise<T>) => pollingExpect(fn, false),
  }
) as unknown as CompatExpect;

/**
 * `expect.poll`: the matcher holds of what `fn` reads, checked again after each
 * test-clock frame until it does (Vitest's own poll waits on the timers the
 * test clock fakes).
 */
function pollingExpect<T>(fn: () => T | Promise<T>, negate: boolean): unknown {
  return new Proxy(
    {},
    {
      get(_, name) {
        if (name === "not") return pollingExpect(fn, !negate);
        return async (...args: unknown[]) => {
          const deadline = waitNow() + defaultTimeout;
          for (;;) {
            try {
              // A read that throws is retried, as Playwright's poll retries it.
              const value = await fn();
              const assertion = negate ? baseExpect(value).not : baseExpect(value);
              await (
                assertion as unknown as Record<string, (...a: unknown[]) => unknown>
              )[name as string]!(...args);
              return;
            } catch (error) {
              if (waitNow() > deadline) throw error;
              await waitNext();
            }
          }
        };
      },
    }
  );
}

// --- test API ----------------------------------------------------------------

type TestInfo = {
  title: string;
  outputPath: (...segments: string[]) => string;
  attach: (name: string, options: unknown) => Promise<void>;
  setTimeout: (timeout: number) => void;
  project: { name: string };
  repeatEachIndex: number;
  retry: number;
};

type BrowserContext = {
  grantPermissions(permissions: string[]): Promise<void>;
  newPage(): Promise<Page>;
  close(): Promise<void>;
};
type TestArgs = {
  page: Page;
  browserName: "chromium";
  context: BrowserContext;
  browser: {
    newContext(options?: {
      viewport?: { width: number; height: number };
    }): Promise<BrowserContext>;
  };
};
type TestBody = (args: TestArgs, testInfo: TestInfo) => Promise<void> | void;

let activePage: Page | undefined;
// Whether the running test's page has mounted its fixture.
let pageMounted = false;
// Code each page of this file runs before its fixture mounts.
let pageInit: (() => void) | undefined;
// The modules the warm-up loaded: each page loads them with its fixture.
const lazyModules = new Set<string>();
let warmingUp = false;
// A module of the test's pages (the built pages, or the fixtures from the dev
// server), not the test runner's own.
const urlOf = (request: string) => request.slice(request.indexOf(" ") + 1);
const isImage = (request: string) => /^(img|image|css) /.test(request);
// How many requests the page had made when its mount ended, and what the
// test's earlier pages requested after theirs.
let mountedRequests = 0;
const testRequests: string[] = [];
// A worker's entry, which the test build gives its seed in its URL
// (./workers): not a module the page imports.
const isWorkerEntry = (request: string) =>
  urlOf(request).includes(`#${workerSeedParameter}=`);
const withoutFragment = (url: string) => url.split("#")[0]!;
// The worker entries the warm-up's pages started. A test's page starts them
// again: a script of the test build, fixed for the run, whose answers reach
// the page at fixed points (./workers), so neither its content nor when it
// loads changes what the page does. The test may load it.
const warmWorkers = new Set<string>();
const isPageModule = (request: string) =>
  !isWorkerEntry(request) &&
  /^(script|link|other) /.test(request) &&
  /\.m?js(\?|$)/.test(urlOf(request)) &&
  (request.includes("/__pages/") ||
    (inject("appShellPages") === "dev" && !/\/(@vite|__vitest|@vitest)/.test(request)));
// A file of the run's own builds: the test build's pages, the shipped web
// build and the dynamic UI frame's document (vitest.config.ts, servedPages,
// servedWebApp and servedDynamicUiFrame).
const isOwnFile = (request: string) => {
  const url = new URL(urlOf(request), location.href);
  if (url.href in externalFiles) return true;
  return (
    url.origin === location.origin &&
    /^\/(__pages|__dynamic-ui|__mini-app|assets|brand)\//.test(url.pathname)
  );
};
// The images mounts in this window loaded, by request ("image <url>").
const loadedImages = new Set<string>();
let fakeMediaSources: FakeMediaSources | undefined;
// Whether the spec's pages are realms of a world (./world).
let pageWorld = false;
// Whether the page's own location is its URL, as the web app's is.
let pageOwnsUrl = false;
// Whether page time moves while an evaluation's promise is pending.
let evaluationsStep = false;
// The realms that answer the pages' requests (./world), read as each page opens.
let pageServers: (() => readonly NodeRealm<unknown>[]) | undefined;
const viewportOverrides: { width: number; height: number }[] = [];
const reducedMotionOverrides: string[] = [];
const scaleOverrides: number[] = [];

// Every test starts from the scale its own `test.use` asks for, so a test that
// failed before restoring it cannot leak it into the next. Touch emulation is
// not offered: on Linux, any Emulation.setTouchEmulationEnabled call leaves the
// page without (hover: hover) for good. Touch specs stay in Playwright, where
// each test gets a fresh context.
async function resetBrowser() {
  forgetFrames();
  activePage?.resetInitScripts();
  await commands.resetBrowserState({
    scale: scaleOverrides.at(-1),
    media: {
      reducedMotion: reducedMotionOverrides.at(-1) ?? "no-preference",
      colorScheme: "light",
      forcedColors: "none",
      contrast: "no-preference",
      media: "screen",
    },
  });
  // The frame takes this test's size first: the point the pointer leaves to
  // is outside the frame it runs in.
  await activePage!.setViewportSize(
    viewportOverrides.at(-1) ?? { width: 1280, height: 800 }
  );
  // The runner's frame, as the top page lays it out: the tests' frame fills it.
  const runner = window.frameElement;
  const box =
    runner && window.top === window.parent ? runner.getBoundingClientRect() : undefined;
  await commands.mouseLeaveFrame(
    box && { x: box.x, y: box.y, width: box.width, height: box.height }
  );
  lastPointer = undefined;
}

/**
 * Binds the spec's fixture to the Playwright-style `test`. `media` describes
 * the sources of a fixture that plays audio or video: its media elements then
 * play them on the test clock (`./fake-media`). The spec's pages run on the UI
 * runtime (`../../ui-runtime/child`); `runtime: false` opens them on fake
 * timers instead (`./child`). `world` makes each page and the workers it
 * starts realms of a world (`./world`), whose time the test clock then
 * moves; its `servers` are the Node realms that answer the pages' requests.
 * `ownsUrl` makes `page.url()` the page's own location, which its navigations
 * change, instead of the URL the test opened. `evaluationsStep` moves page
 * time while an evaluation waits for the page's frames or animations; without
 * it an evaluation waits only for the page to settle, as what it awaits may
 * come from outside the world (a clipboard read, an image decode).
 */
/** A URL to render, or steps that drive the fixture as a test would. */
type WarmUp = string | ((page: Page) => Promise<void>);

export function useFixture(
  mount: Mount,
  options: {
    media?: FakeMediaSources;
    warmUp?: WarmUp[];
    pageInit?: () => void;
    runtime?: boolean;
    world?: boolean | { servers: () => readonly NodeRealm<unknown>[] };
    ownsUrl?: boolean;
    evaluationsStep?: boolean;
  } = {}
) {
  activePage = createPage(mount);
  setPageRuntime(options.runtime ?? true);
  pageWorld = Boolean(options.world);
  pageOwnsUrl = options.ownsUrl ?? false;
  evaluationsStep = options.evaluationsStep ?? false;
  pageServers = typeof options.world === "object" ? options.world.servers : undefined;
  fakeMediaSources = options.media;
  pageInit = options.pageInit;
  // Before any test, the fixture renders once at each `warmUp` URL (or as its
  // steps drive it) with page time running until nothing loads. The modules
  // it loaded lazily after its mount (a highlighter, a math or diagram
  // renderer) each test's page loads with its fixture, so the test itself
  // makes no request.
  const warmUp = options.warmUp ?? [];
  if (warmUp.length > 0)
    beforeAll(async () => {
      const page = activePage!;
      const start = realNow();
      setPageSeed(seedFor("warm-up"));
      for (const step of warmUp) {
        await startTestClock();
        pageMounted = false;
        warmingUp = true;
        try {
          if (typeof step === "string") await page.goto(step);
          else await step(pageArgs().page);
          for (let round = 0; round < 40; round += 1) {
            await testClock().advance(250);
            await testPage().importsLoaded();
          }
          for (const request of testPage().resources()) {
            if (isPageModule(request)) lazyModules.add(urlOf(request));
            if (isWorkerEntry(request))
              warmWorkers.add(withoutFragment(urlOf(request)));
          }
        } finally {
          warmingUp = false;
          await stopTestClock();
        }
      }
      warmedUp(realNow() - start);
    });
  // Each test, its own hooks included, runs on the test clock from before its
  // fixture mounts: nothing in it runs on real time.
  beforeEach(async (context) => {
    setPageSeed(seedFor(`${context.task.file.name} > ${context.task.name}`));
    // The browser's own state (its viewport, media emulation, pointer, keys,
    // permissions) outlives a page: each test sets all of it to the same
    // start before its page opens, ahead of the file's own hooks.
    startTiming();
    await timed("reset", resetBrowser);
    await timed("open", async () => {
      await startTestClock();
      // A fresh page has the focus, with no pointer use that would keep a
      // programmatic focus from matching :focus-visible.
      await commands.focusFrame();
      win().focus();
    });
    pageMounted = false;
    mountedRequests = 0;
    testRequests.length = 0;
    forgetWorld();
  });
  afterEach(async (context) => {
    await timed("close", stopTestClock);
    // The closed page's memory goes now, not when the browser next needs it:
    // three shards share the CI VM's 4.6 GB, and a page each test leaves
    // grows a shard's Chromium by a third over a long file.
    await commands.cdpSend("HeapProfiler.collectGarbage", {});
    await reportTiming(`clients/${context.task.file.name}`, context.task.name);
  });
}

function testInfo(title: string): TestInfo {
  return {
    title,
    outputPath: (...segments) => segments.join("/"),
    attach: async () => {},
    setTimeout: () => {},
    project: { name: "chromium" },
    repeatEachIndex: 0,
    retry: 0,
  };
}

function wrap(title: string, body: TestBody) {
  return async (context: { task: { file: { name: string } } }) => {
    await beginRecord(`clients/${context.task.file.name}`, title);
    if (!activePage) throw new Error("Call useFixture() before declaring tests.");
    currentTestInfo = testInfo(title);
    let status = "passed";
    try {
      await timed("steps", async () => body(pageArgs(), currentTestInfo!));
      // The page drew its random numbers from the test's seed throughout
      // (./random): code that replaced a source would draw outside it.
      if (runningClock() && !testPage().randomSeeded())
        throw new Error(
          "The test page replaced Math.random, crypto.getRandomValues or crypto.randomUUID: its random numbers left the test's seed."
        );
      const violations = runningClock() ? (testPage().violations?.() ?? []) : [];
      if (violations.length > 0)
        throw new Error(
          `The test page did what its UI runtime does not control:\n${violations.join("\n")}`
        );
      // A test makes no request: what it needs loaded with its fixture. An
      // image that a mount in this window loaded shows again from memory.
      const requests = [
        ...testRequests,
        ...testPage().resources().slice(mountedRequests),
      ].filter(
        (request) =>
          !(isImage(request) && loadedImages.has(urlOf(request))) &&
          // A world's page loads its files as the app does, on demand: each
          // is work of the page's runtime, delivered in the order it started.
          !(pageWorld && isOwnFile(request)) &&
          // A request to a realm of the test's world is a message of the world.
          !urlOf(request).includes(`${worldRequestParameter}=`) &&
          !(isWorkerEntry(request) && warmWorkers.has(withoutFragment(urlOf(request))))
      );
      if (requests.length > 0) {
        // Whether the warm-up had the module, and how many it recorded: a
        // module it had loaded again in the test.
        const listed = requests.map((request) =>
          lazyModules.has(urlOf(request))
            ? `${request} (loaded with the fixture)`
            : request
        );
        throw new Error(
          `The test made requests (the warm-up recorded ${lazyModules.size} modules):\n${listed.join("\n")}`
        );
      }
    } catch (error) {
      status = "failed";
      throw error;
    } finally {
      await timed("end", async () => {
        if (runningClock())
          pageTimeSpent(testPage().nativeFrames(), testPage().mountTimes());
        await endRecord(
          `clients/${context.task.file.name}`,
          title,
          status,
          runningClock() ? testPage().frameState() : undefined
        );
      });
    }
  };
}

type TestFn = {
  (title: string, body: TestBody): void;
  (title: string, details: { tag?: string | string[] }, body: TestBody): void;
  describe: typeof describeCompat;
  beforeAll: (fn: (args: TestArgs) => unknown) => void;
  afterAll: (fn: (args: TestArgs) => unknown) => void;
  beforeEach: (fn: (args: TestArgs, testInfo: TestInfo) => unknown) => void;
  afterEach: (fn: (args: TestArgs, testInfo: TestInfo) => unknown) => void;
  use: (options: {
    viewport?: { width: number; height: number };
    reducedMotion?: string;
    locale?: string;
    deviceScaleFactor?: number;
  }) => void;
  skip: (condition?: boolean | string, reason?: string) => void;
  setTimeout: (timeout: number) => void;
  fixme: (title: string, body: TestBody) => void;
  slow: () => void;
  step: <T>(title: string, body: () => Promise<T>) => Promise<T>;
  info: () => TestInfo;
};

let currentTestInfo: TestInfo | undefined;

function browserContext(
  options: { viewport?: { width: number; height: number } } = {}
): BrowserContext {
  return {
    grantPermissions: (permissions) => commands.grantPermissions(permissions),
    async newPage() {
      if (options.viewport) await activePage!.setViewportSize(options.viewport);
      return activePage!;
    },
    async close() {},
  };
}

const pageArgs = (): TestArgs => ({
  page: activePage!,
  browserName: "chromium",
  context: browserContext(),
  browser: { newContext: async (options) => browserContext(options) },
});

function describeCompat(title: string, body: () => void): void;
function describeCompat(title: string, details: object, body: () => void): void;
function describeCompat(title: string, ...rest: unknown[]) {
  const body = rest.at(-1) as () => void;
  describe(title, body);
}

export const test = Object.assign(
  (title: string, ...rest: unknown[]) => {
    const body = rest.at(-1) as TestBody;
    it(title, wrap(title, body));
  },
  {
    describe: describeCompat,
    beforeAll: (fn: (args: TestArgs) => unknown) =>
      beforeAll(async () => fn(pageArgs())),
    afterAll: (fn: (args: TestArgs) => unknown) => afterAll(async () => fn(pageArgs())),
    beforeEach: (fn: (args: TestArgs, testInfo: TestInfo) => unknown) =>
      beforeEach(async (context) => fn(pageArgs(), testInfo(context.task.name))),
    afterEach: (fn: (args: TestArgs, testInfo: TestInfo) => unknown) =>
      afterEach(async (context) => fn(pageArgs(), testInfo(context.task.name))),
    use: (options: {
      viewport?: { width: number; height: number };
      reducedMotion?: string;
      deviceScaleFactor?: number;
    }) => {
      if (options.deviceScaleFactor) {
        const scale = options.deviceScaleFactor;
        beforeAll(() => {
          scaleOverrides.push(scale);
        });
        afterAll(() => {
          scaleOverrides.pop();
        });
      }
      if (options.viewport) {
        const size = options.viewport;
        beforeAll(() => {
          viewportOverrides.push(size);
        });
        afterAll(() => {
          viewportOverrides.pop();
        });
      }
      if (options.reducedMotion) {
        const value = options.reducedMotion;
        beforeAll(() => {
          reducedMotionOverrides.push(value);
        });
        afterAll(() => {
          reducedMotionOverrides.pop();
        });
      }
    },
    skip: (condition?: boolean | string) => {
      if (condition === true) throw new Error("Use it.skipIf in the browser project.");
    },
    setTimeout: () => {},
    fixme: (title: string) => it.todo(title),
    slow: () => {},
    step: async <T>(_title: string, body: () => Promise<T>) => body(),
    info: () => currentTestInfo!,
  }
) as unknown as TestFn;
