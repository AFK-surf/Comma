// Locators in a frame of another origin: a sandboxed frame of the test page,
// a realm of its world (../../ui-runtime/frame-realm.ts). The test cannot
// reach into such a frame; it reads it through an isolated world of the frame
// (CDP), which shares the frame's document but none of its scripts, and acts
// on it as a person does, by the browser's trusted input at the element's
// place on the page. Reading moves no time; a wait steps the test clock a
// frame at a time, as the page's own locators do (./page.ts).
import { commands } from "vitest/browser";
import type { FrameStep, TextMatch } from "../../ui-runtime/frame-query";
import { pageWindow, testClock } from "./virtual-time";

declare module "vitest/browser" {
  interface BrowserCommands {
    /** The script of a frame's locators (e2e/ui-runtime/frame-query.ts). */
    frameQueryEngine: () => Promise<string>;
  }
}

type FrameTree = { frame: { id: string; name?: string }; childFrames?: FrameTree[] };
type Pointer = {
  mouse: {
    move(x: number, y: number): Promise<void>;
    click(
      x: number,
      y: number,
      options?: { button?: "left" | "right" | "middle"; clickCount?: number }
    ): Promise<void>;
  };
  keyboard: {
    press(key: string): Promise<void>;
    insertText(text: string): Promise<void>;
  };
};

const defaultFrames = 625; // 10 s of page time, as the page's locators wait
const contexts = new Map<string, number>();
let engine: Promise<string> | undefined;

function findFrame(tree: FrameTree, name: string): string | undefined {
  if (tree.frame.name === name) return tree.frame.id;
  for (const child of tree.childFrames ?? []) {
    const found = findFrame(child, name);
    if (found) return found;
  }
  return undefined;
}

/** Evaluates `expression` in the isolated world of the frame called `name`, its value returned. */
async function inFrame<T>(name: string, expression: string): Promise<T> {
  for (let attempt = 0; ; attempt += 1) {
    let context = contexts.get(name);
    if (context === undefined) {
      const { frameTree } = (await commands.cdpSend("Page.getFrameTree")) as {
        frameTree: FrameTree;
      };
      const frameId = findFrame(frameTree, name);
      if (!frameId) throw new Error(`No frame ${name} on the page.`);
      const created = (await commands.cdpSend("Page.createIsolatedWorld", {
        frameId,
        worldName: "comma-frame-query",
      })) as { executionContextId: number };
      context = created.executionContextId;
      engine ??= commands.frameQueryEngine();
      await commands.cdpSend("Runtime.evaluate", {
        contextId: context,
        expression: await engine,
      });
      contexts.set(name, context);
    }
    const result = (await commands
      .cdpSend("Runtime.evaluate", {
        contextId: context,
        expression,
        returnByValue: true,
        awaitPromise: true,
      })
      .catch((error: unknown) => {
        // A frame that loaded again has a context of its own.
        contexts.delete(name);
        if (attempt === 0) return undefined;
        throw error;
      })) as
      | {
          result: { value?: T };
          exceptionDetails?: { exception?: { description?: string } };
        }
      | undefined;
    if (!result) continue;
    if (result.exceptionDetails)
      throw new Error(
        result.exceptionDetails.exception?.description ?? "evaluation failed"
      );
    return result.result.value as T;
  }
}

/** Forgets the frames' isolated worlds: the next test's frames are new. */
export function forgetFrames() {
  contexts.clear();
}

const textMatch = (text: string | RegExp, exact?: boolean): TextMatch =>
  typeof text === "string"
    ? { text, exact: exact ?? false }
    : { pattern: text.source, flags: text.flags };

type Box = { x: number; y: number; width: number; height: number };

export class FrameElementLocator {
  constructor(
    private readonly frame: FrameLocator,
    readonly steps: readonly FrameStep[],
    readonly description: string
  ) {}

  private chain(next: FrameStep, description: string) {
    return new FrameElementLocator(
      this.frame,
      [...this.steps, next],
      `${this.description} >> ${description}`
    );
  }

  locator(selector: string) {
    return this.chain({ css: selector }, selector);
  }
  getByRole(
    role: string,
    options: {
      name?: string | RegExp;
      exact?: boolean;
      checked?: boolean;
      disabled?: boolean;
      level?: number;
      includeHidden?: boolean;
    } = {}
  ) {
    const { name, exact, ...rest } = options;
    return this.chain(
      {
        role,
        ...rest,
        ...(name === undefined ? {} : { name: textMatch(name, exact) }),
      },
      `role=${role}`
    );
  }
  getByText(text: string | RegExp, options: { exact?: boolean } = {}) {
    return this.chain({ text: textMatch(text, options.exact) }, `text=${String(text)}`);
  }
  getByLabel(text: string | RegExp, options: { exact?: boolean } = {}) {
    return this.chain(
      { label: textMatch(text, options.exact) },
      `label=${String(text)}`
    );
  }
  nth(index: number) {
    return this.chain({ nth: index }, `nth=${index}`);
  }
  first() {
    return this.nth(0);
  }
  last() {
    return this.nth(-1);
  }

  /** Runs `body` on the located elements in the frame's isolated world. */
  query<T>(body: string): Promise<T> {
    return this.frame.inFrame(
      `(() => { const elements = commaFrameQuery.all(${JSON.stringify(this.steps)}); ${body} })()`
    );
  }
  count() {
    return this.query<number>("return elements.length;");
  }
  async all() {
    const count = await this.count();
    return Array.from({ length: count }, (_, index) => this.nth(index));
  }
  private one<T>(body: string) {
    return this.query<T>(
      `if (elements.length !== 1) throw new Error(${JSON.stringify(
        `${this.description} matches `
      )} + elements.length + " elements"); const element = elements[0]; ${body}`
    );
  }
  textContent() {
    return this.one<string | null>("return element.textContent;");
  }
  innerText() {
    return this.one<string>("return element.innerText;");
  }
  getAttribute(name: string) {
    return this.one<string | null>(
      `return element.getAttribute(${JSON.stringify(name)});`
    );
  }
  /** Runs `fn(element, arg)` in the frame's isolated world: it sees the frame's document only. */
  evaluate<R, A = undefined, E extends Element = HTMLElement>(
    fn: (element: E, arg: A) => R | Promise<R>,
    arg?: A
  ): Promise<R> {
    return this.one<R>(
      `return (${fn.toString()})(element, ${JSON.stringify(arg ?? null)});`
    );
  }
  /** Runs `fn(elements, arg)` over every located element in the frame's isolated world. */
  evaluateAll<R, A = undefined, E extends Element = HTMLElement>(
    fn: (elements: E[], arg: A) => R | Promise<R>,
    arg?: A
  ): Promise<R> {
    return this.query<R>(
      `return (${fn.toString()})(elements, ${JSON.stringify(arg ?? null)});`
    );
  }
  async blur() {
    await this.one("element.blur(); return null;");
  }
  /** The element's box on the page. */
  async boundingBox(): Promise<Box | null> {
    const inner = await this.one<Box | null>(
      "const r = element.getBoundingClientRect(); return r.width || r.height ? { x: r.x, y: r.y, width: r.width, height: r.height } : null;"
    );
    if (!inner) return null;
    const outer = this.frame.element().getBoundingClientRect();
    const frame = this.frame.element();
    return {
      x: outer.x + frame.clientLeft + inner.x,
      y: outer.y + frame.clientTop + inner.y,
      width: inner.width,
      height: inner.height,
    };
  }
  /** Waits as Playwright's actions do: one element, visible and in one place for a frame. */
  /**
   * Waits as Playwright's actions do: one element, visible, in one place for a
   * frame, and the point the input will hit is the element's, in the frame
   * and inside the frame's box on the page. Returns that point on the page.
   */
  private async actionable(position?: { x: number; y: number }) {
    let previous = "";
    for (let frame = 0; ; frame += 1) {
      const count = await this.count();
      const box = count === 1 ? await this.boundingBox() : null;
      const current = box ? JSON.stringify(box) : "";
      if (box && current === previous) {
        const x = box.x + (position?.x ?? box.width / 2);
        const y = box.y + (position?.y ?? box.height / 2);
        // Like Playwright, bring the point that will be hit into the page's view.
        const view = pageWindow();
        if (y < 0 || y >= view.innerHeight || x < 0 || x >= view.innerWidth) {
          view.scrollBy(
            x < 0 || x >= view.innerWidth ? x - view.innerWidth / 2 : 0,
            y < 0 || y >= view.innerHeight ? y - view.innerHeight / 2 : 0
          );
          previous = "";
          await testClock().advanceFrames(1);
          continue;
        }
        const outer = this.frame.element().getBoundingClientRect();
        const inside =
          x >= outer.left && x < outer.right && y >= outer.top && y < outer.bottom;
        const hit =
          inside &&
          (await this.one<boolean>(
            `const top = document.elementFromPoint(${x - outer.x - this.frame.element().clientLeft}, ${y - outer.y - this.frame.element().clientTop}); return top === element || element.contains(top);`
          ));
        if (hit) return { x, y };
      }
      previous = current;
      if (frame >= defaultFrames)
        throw new Error(
          `Timed out waiting for ${this.description} to receive pointer events`
        );
      await testClock().advanceFrames(1);
    }
  }
  async click(
    options: {
      button?: "left" | "right" | "middle";
      clickCount?: number;
      position?: { x: number; y: number };
    } = {}
  ) {
    const { x, y } = await this.actionable(options.position);
    await this.frame.pointer().mouse.click(x, y, options);
  }
  async hover() {
    const { x, y } = await this.actionable();
    await this.frame.pointer().mouse.move(x, y);
  }
  async focus() {
    await this.one("element.focus(); return null;");
  }
  async press(key: string) {
    await this.focus();
    await this.frame.pointer().keyboard.press(key);
  }
  async fill(value: string) {
    await this.one(
      "element.focus(); if ('select' in element) element.select(); return null;"
    );
    await this.frame.pointer().keyboard.insertText(value);
  }
  /** Picks the options whose value or label is `value`, as Playwright does: the element's events, not input. */
  async selectOption(value: string | string[]) {
    await this.one(`
      const wanted = ${JSON.stringify([value].flat())};
      for (const option of element.options) option.selected = wanted.includes(option.value) || wanted.includes(option.label);
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
      return null;`);
  }
  /** An event the test makes, not the browser: untrusted, as Playwright's dispatchEvent. */
  async dispatchEvent(type: string, init: Record<string, unknown> = {}) {
    await this.one(
      `element.dispatchEvent(new Event(${JSON.stringify(type)}, { bubbles: true, cancelable: true, composed: true, ...${JSON.stringify(init)} })); return null;`
    );
  }

  /** The element's state for an assertion, read at once. */
  state() {
    return this.query<{
      count: number;
      visible: boolean;
      text: string;
      texts: string[];
      attributes: Record<string, string>;
      style: Record<string, string>;
      checked: boolean;
      disabled: boolean;
      value: string;
    }>(`
      const element = elements[0];
      if (!element) return { count: 0, visible: false, text: "", texts: [], attributes: {}, style: {}, checked: false, disabled: false, value: "" };
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return {
        count: elements.length,
        visible: element.isConnected && element.checkVisibility({ visibilityProperty: true }) && rect.width > 0 && rect.height > 0,
        text: element.textContent ?? "",
        texts: elements.map((each) => each.textContent ?? ""),
        attributes: Object.fromEntries([...element.attributes].map((a) => [a.name, a.value])),
        style: Object.fromEntries([...style].map((name) => [name, style.getPropertyValue(name)])),
        checked: Boolean(element.checked),
        disabled: Boolean(element.disabled),
        value: "value" in element ? String(element.value) : "",
      };`);
  }
}

export class FrameLocator {
  constructor(
    private readonly frameElement: () => HTMLIFrameElement,
    private readonly page: Pointer
  ) {}

  element() {
    return this.frameElement();
  }
  pointer() {
    return this.page;
  }
  /** The frame's realm's name; until its realm has set up (its document loading), page time moves on. */
  async name() {
    const view = pageWindow() as Window & {
      commaFrames?: { names(): string[]; nameOf(target: HTMLIFrameElement): string };
    };
    for (let frame = 0; ; frame += 1) {
      try {
        if (!view.commaFrames) throw new Error("The page has no frames of its world.");
        return view.commaFrames.nameOf(this.frameElement());
      } catch (error) {
        if (frame >= defaultFrames) throw error;
      }
      await testClock().advanceFrames(1);
    }
  }
  async inFrame<T>(expression: string) {
    return inFrame<T>(await this.name(), expression);
  }
  locator(selector: string) {
    return new FrameElementLocator(this, [{ css: selector }], selector);
  }
  getByRole(...args: Parameters<FrameElementLocator["getByRole"]>) {
    return new FrameElementLocator(this, [], "frame").getByRole(...args);
  }
  getByText(...args: Parameters<FrameElementLocator["getByText"]>) {
    return new FrameElementLocator(this, [], "frame").getByText(...args);
  }
  getByLabel(...args: Parameters<FrameElementLocator["getByLabel"]>) {
    return new FrameElementLocator(this, [], "frame").getByLabel(...args);
  }
}

type State = Awaited<ReturnType<FrameElementLocator["state"]>>;

/** Playwright's locator assertions over a frame's elements, waiting on page time. */
export function expectFrameLocator(locator: FrameElementLocator) {
  const assert = (negate: boolean) => {
    const check = async (
      holds: (state: State) => boolean,
      what: string,
      received: (state: State) => unknown
    ) => {
      let state: State | undefined;
      for (let frame = 0; ; frame += 1) {
        state = await locator.state();
        if (holds(state) !== negate) return;
        if (frame >= defaultFrames)
          throw new Error(
            `expect(${locator.description}).${negate ? "not." : ""}${what} failed; received ${JSON.stringify(received(state))}`
          );
        await testClock().advanceFrames(1);
      }
    };
    const textOf = (text: string | RegExp, exact: boolean) => (state: State) =>
      typeof text === "string"
        ? exact
          ? state.text.replace(/\s+/g, " ").trim() === text.replace(/\s+/g, " ").trim()
          : state.text.replace(/\s+/g, " ").includes(text.replace(/\s+/g, " "))
        : text.test(state.text);
    return {
      toBeVisible: () =>
        check(
          (s) => s.count === 1 && s.visible,
          "toBeVisible()",
          (s) => s.count
        ),
      toBeHidden: () =>
        check(
          (s) => !s.visible,
          "toBeHidden()",
          (s) => s.count
        ),
      toHaveCount: (count: number) =>
        check(
          (s) => s.count === count,
          `toHaveCount(${count})`,
          (s) => s.count
        ),
      toHaveText: (text: string | RegExp | (string | RegExp)[]) =>
        Array.isArray(text)
          ? check(
              (s) =>
                s.texts.length === text.length &&
                s.texts.every((each, index) =>
                  textOf(text[index]!, true)({ ...s, text: each })
                ),
              `toHaveText(${JSON.stringify(text.map(String))})`,
              (s) => s.texts
            )
          : check(
              (s) => s.count === 1 && textOf(text, true)(s),
              `toHaveText(${String(text)})`,
              (s) => s.text
            ),
      toContainText: (text: string | RegExp) =>
        check(
          (s) => s.count === 1 && textOf(text, false)(s),
          `toContainText(${String(text)})`,
          (s) => s.text
        ),
      toBeEmpty: () =>
        check(
          (s) => s.count === 1 && s.text.trim() === "",
          "toBeEmpty()",
          (s) => s.text
        ),
      toHaveCSS: (name: string, value: string | RegExp) =>
        check(
          (s) =>
            s.count === 1 &&
            (typeof value === "string"
              ? s.style[name] === value
              : value.test(s.style[name] ?? "")),
          `toHaveCSS(${name}, ${String(value)})`,
          (s) => s.style[name]
        ),
      toHaveAttribute: (name: string, value?: string | RegExp) =>
        check(
          (s) =>
            s.count === 1 &&
            name in s.attributes &&
            (value === undefined ||
              (typeof value === "string"
                ? s.attributes[name] === value
                : value.test(s.attributes[name]!))),
          `toHaveAttribute(${name})`,
          (s) => s.attributes[name]
        ),
      toBeChecked: () =>
        check(
          (s) => s.count === 1 && s.checked,
          "toBeChecked()",
          (s) => s.checked
        ),
      toBeDisabled: () =>
        check(
          (s) => s.count === 1 && s.disabled,
          "toBeDisabled()",
          (s) => s.disabled
        ),
      toHaveValue: (value: string) =>
        check(
          (s) => s.count === 1 && s.value === value,
          `toHaveValue(${value})`,
          (s) => s.value
        ),
    };
  };
  return { ...assert(false), not: assert(true) };
}
