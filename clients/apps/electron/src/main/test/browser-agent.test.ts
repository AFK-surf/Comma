import { describe, expect, it } from "vitest";
import {
  BrowserAgentSession,
  parseChord,
  type BrowserAgentRefs,
} from "../modules/browser-sidebar/agent";
import { ManualMainClock } from "../test-clock";

type Listener = (method: string, params: Record<string, unknown>) => void;
type Answer = (
  params: Record<string, unknown>,
  page: FakePage
) => unknown | Promise<unknown>;

/**
 * A tab's CDP session. Page helper calls are answered by the last line of the
 * evaluated expression (the call after the page script), matched by name.
 */
class FakePage {
  readonly sent: Array<{ method: string; params: Record<string, unknown> }> = [];
  readonly #listeners = new Set<Listener>();
  readonly #answers: Record<string, Answer>;
  readonly #helpers: Record<string, unknown>;

  constructor({
    answers = {},
    helpers = {},
  }: {
    answers?: Record<string, Answer>;
    helpers?: Record<string, unknown>;
  }) {
    this.#answers = answers;
    this.#helpers = {
      snapshot: {
        text: '- button "Save" [e1]',
        title: "Shop",
        url: "https://shop.test/",
        next: 2,
      },
      ...helpers,
    };
  }

  emit(method: string, params: Record<string, unknown> = {}) {
    for (const listener of this.#listeners) listener(method, params);
  }

  calls(method: string) {
    return this.sent.filter((entry) => entry.method === method);
  }

  helperCalls() {
    return this.calls("Runtime.evaluate").map((entry) =>
      String(entry.params.expression).split("\n").at(-1)
    );
  }

  readonly cdp = {
    send: async (method: string, params: Record<string, unknown> = {}) => {
      this.sent.push({ method, params });
      const answer = this.#answers[method];
      if (answer) return answer(params, this);
      switch (method) {
        case "Page.getFrameTree":
          return { frameTree: { frame: { id: "main", loaderId: "doc-1" } } };
        case "Page.createIsolatedWorld":
          return { executionContextId: 7 };
        case "Runtime.evaluate": {
          const call = String(params.expression).split("\n").at(-1)!;
          const name = Object.keys(this.#helpers).find((helper) =>
            call.includes(`__commaAgent.${helper}(`)
          );
          if (call.includes("__commaAgent.element(")) {
            // An element call: `{ value }` of its helper, or null for armClick/focus.
            const helper = Object.keys(this.#helpers).find((key) =>
              call.includes(`__commaAgent.${key}(el`)
            );
            return {
              result: { value: { value: helper ? this.#helpers[helper] : null } },
            };
          }
          return { result: { value: name ? this.#helpers[name] : undefined } };
        }
        default:
          return {};
      }
    },
    onEvent: (listener: Listener) => {
      this.#listeners.add(listener);
      return () => this.#listeners.delete(listener);
    },
  };
}

function session(page: FakePage, refs?: BrowserAgentRefs) {
  const tab = {
    cdp: page.cdp,
    clock: new ManualMainClock(),
    navigate: async () => undefined,
    platform: "darwin" as const,
    refs,
    tabId: "tab-a",
    title: () => "Shop",
    url: () => "https://shop.test/",
  };
  return { session: new BrowserAgentSession(tab), tab };
}

describe("in-app browser agent session", () => {
  it("stops a batch at the first step that cannot run and still returns the page", async () => {
    const page = new FakePage({
      helpers: {
        resolve: { ref: "e1", next: 2 },
        numberFill: null,
        prepareFill: null,
      },
      answers: {
        "Runtime.evaluate": (params) => {
          const call = String(params.expression).split("\n").at(-1)!;
          if (call.includes('"text":"Checkout"')) {
            return { result: { value: { error: "target_not_found", next: 2 } } };
          }
          if (call.includes("__commaAgent.resolve(")) {
            return { result: { value: { ref: "e1", next: 2 } } };
          }
          if (call.includes("__commaAgent.snapshot(")) {
            return {
              result: {
                value: {
                  text: '- textbox "Search" [e1] value="milk"',
                  title: "Shop",
                  url: "https://shop.test/",
                  next: 2,
                },
              },
            };
          }
          return { result: { value: { value: null } } };
        },
      },
    });
    const { session: agent } = session(page, { document: "doc-1", next: 2 });

    const result = await agent.command("actions", {
      tabId: "tab-a",
      steps: [
        { op: "fill", ref: "e1", text: "milk" },
        { op: "click", target: "text=Checkout" },
        { op: "press", key: "Enter" },
      ],
    });

    expect(result).toMatchObject({
      failedStep: { error: "target_not_found", index: 1, op: "click" },
      snapshot: '- textbox "Search" [e1] value="milk"',
      stepsCompleted: 1,
      url: "https://shop.test/",
    });
    expect(page.calls("Input.insertText")).toEqual([
      { method: "Input.insertText", params: { text: "milk" } },
    ]);
    expect(page.calls("Input.dispatchKeyEvent")).toEqual([]);
  });

  it("holds a dialog that a click opened until the agent answers it", async () => {
    const page = new FakePage({
      helpers: { resolve: { ref: "e1", next: 2 }, clickPoint: { x: 40, y: 20 } },
      answers: {
        "Input.dispatchMouseEvent": (params, fake) => {
          if (params.type !== "mousePressed") return {};
          // The page's handler shows confirm(): the press is never acknowledged.
          fake.emit("Page.javascriptDialogOpening", {
            message: "Delete item?",
            type: "confirm",
          });
          return new Promise(() => undefined);
        },
        "Page.handleJavaScriptDialog": (_params, fake) => {
          fake.emit("Page.javascriptDialogClosed");
          return {};
        },
      },
    });
    const { session: agent } = session(page, { document: "doc-1", next: 2 });

    await expect(
      agent.command("click", { tabId: "tab-a", ref: "e1" })
    ).resolves.toEqual({
      dialog: { message: "Delete item?", type: "confirm" },
      tabId: "tab-a",
      title: "Shop",
      url: "https://shop.test/",
    });
    expect(agent.holding).toBe(true);
    // The release would not reach a page that a dialog holds.
    expect(
      page.calls("Input.dispatchMouseEvent").map((entry) => entry.params.type)
    ).toEqual(["mouseMoved", "mousePressed"]);
    await expect(agent.command("snapshot", { tabId: "tab-a" })).resolves.toMatchObject({
      dialog: { message: "Delete item?" },
      error: "dialog_open",
    });

    await expect(
      agent.command("dialog", { tabId: "tab-a", action: "accept" })
    ).resolves.toMatchObject({
      handledDialog: { message: "Delete item?", type: "confirm" },
      snapshot: '- button "Save" [e1]',
    });
    expect(page.calls("Page.handleJavaScriptDialog")).toEqual([
      { method: "Page.handleJavaScriptDialog", params: { accept: true } },
    ]);
    expect(agent.holding).toBe(false);
  });

  it("lets the tab count as focused before its first input, once per session", async () => {
    const page = new FakePage({
      answers: {
        "Runtime.evaluate": (params) => {
          const call = String(params.expression).split("\n").at(-1)!;
          if (call.includes("__commaAgent.resolve(")) {
            return { result: { value: { ref: "e1", next: 2 } } };
          }
          if (call.includes("__commaAgent.snapshot(")) {
            return {
              result: {
                value: { next: 2, text: "", title: "Shop", url: "https://shop.test/" },
              },
            };
          }
          return { result: { value: { value: null } } };
        },
      },
    });
    const { session: agent } = session(page, { document: "doc-1", next: 2 });

    await agent.command("actions", {
      tabId: "tab-a",
      steps: [
        { op: "fill", ref: "e1", text: "milk" },
        { op: "press", key: "Enter" },
      ],
    });

    const sent = page.sent
      .map((entry) => entry.method)
      .filter(
        (method) => method.startsWith("Input.") || method.startsWith("Emulation.")
      );
    expect(sent).toEqual([
      "Emulation.setFocusEmulationEnabled",
      "Input.insertText",
      "Input.dispatchKeyEvent",
      "Input.dispatchKeyEvent",
    ]);
  });

  it("says so when a dialog it reported closed before the agent answered", async () => {
    const page = new FakePage({
      helpers: { resolve: { ref: "e1", next: 2 }, clickPoint: { x: 40, y: 20 } },
      answers: {
        "Input.dispatchMouseEvent": (params, fake) => {
          if (params.type !== "mousePressed") return {};
          fake.emit("Page.javascriptDialogOpening", {
            message: "Delete item?",
            type: "confirm",
          });
          return new Promise(() => undefined);
        },
      },
    });
    const { session: agent } = session(page, { document: "doc-1", next: 2 });
    await agent.command("click", { tabId: "tab-a", ref: "e1" });
    // The user (or another debugger client) dismisses it.
    page.emit("Page.javascriptDialogClosed");

    expect(agent.holding).toBe(false);
    await expect(
      agent.command("dialog", { tabId: "tab-a", action: "accept" })
    ).resolves.toMatchObject({
      closedDialog: { message: "Delete item?" },
      error: "invalid_input",
    });
    expect(page.calls("Page.handleJavaScriptDialog")).toEqual([]);
  });

  it("counts a key that opened a dialog as pressed", async () => {
    const page = new FakePage({
      answers: {
        "Input.dispatchKeyEvent": (params, fake) => {
          if (params.type !== "keyDown") return {};
          // Enter submits a form whose handler shows confirm().
          fake.emit("Page.javascriptDialogOpening", {
            message: "Submit?",
            type: "confirm",
          });
          return new Promise(() => undefined);
        },
      },
    });
    const { session: agent } = session(page, { document: "doc-1", next: 2 });

    await expect(
      agent.command("actions", {
        tabId: "tab-a",
        steps: [{ op: "press", key: "Enter" }],
      })
    ).resolves.toMatchObject({
      dialog: { message: "Submit?" },
      stepsCompleted: 1,
    });
    expect(
      page.calls("Input.dispatchKeyEvent").map((entry) => entry.params.type)
    ).toEqual(["keyDown"]);
  });

  it("starts no step after the batch's budget is spent", async () => {
    const clock = new ManualMainClock();
    const page = new FakePage({
      answers: {
        // Each scroll takes four seconds of the page's time.
        "Runtime.evaluate": async (params) => {
          if (String(params.expression).split("\n").at(-1)!.includes("scrollBy(")) {
            await clock.advanceTo(clock.now() + 4_000);
          }
          if (String(params.expression).includes("__commaAgent.snapshot(")) {
            return {
              result: {
                value: { next: 2, text: "", title: "Shop", url: "https://shop.test/" },
              },
            };
          }
          return { result: { value: {} } };
        },
      },
    });
    const agent = new BrowserAgentSession({
      ...session(page).tab,
      clock,
    });

    await expect(
      agent.command("actions", {
        tabId: "tab-a",
        steps: Array.from({ length: 10 }, () => ({ op: "scroll" as const, y: 400 })),
      })
    ).resolves.toMatchObject({
      failedStep: { error: "batch_timeout", index: 5, op: "scroll" },
      stepsCompleted: 5,
    });
  });

  it("fails a navigation whose committed document is Chromium's error page", async () => {
    const page = new FakePage({
      answers: {
        "Runtime.evaluate": () => ({ result: { value: true } }),
      },
    });
    const { tab } = session(page);
    const agent = new BrowserAgentSession({
      ...tab,
      // The error page commits while the load has not reported its error yet.
      navigate: () => {
        page.emit("Page.frameNavigated", {
          frame: {
            id: "main",
            loaderId: "doc-2",
            unreachableUrl: "https://unreachable.test/",
            url: "chrome-error://chromewebdata/",
          },
        });
        return new Promise(() => undefined);
      },
    });

    await expect(
      agent.command("navigate", { tabId: "tab-a", url: "https://unreachable.test/" })
    ).resolves.toMatchObject({
      error: "browser_operation_failed",
      message: "https://unreachable.test/ could not be loaded.",
    });
  });

  it("refuses a ref that an earlier document issued without touching the page", async () => {
    const page = new FakePage({});
    const { session: agent, tab } = session(page, { document: "doc-0", next: 9 });

    await expect(
      agent.command("click", { tabId: "tab-a", ref: "e3" })
    ).resolves.toEqual({
      error: "stale_element",
      tabId: "tab-a",
    });
    expect(page.calls("Runtime.evaluate")).toEqual([]);

    // A snapshot of the new document issues refs after the old ones.
    await agent.command("snapshot", { tabId: "tab-a" });
    expect(page.helperCalls()).toEqual([
      expect.stringContaining('"next":9,"reset":true'),
    ]);
    expect(tab.refs).toEqual({ document: "doc-1", next: 2 });
  });

  it("presses ControlOrMeta as the platform's shortcut modifier", () => {
    expect(parseChord("ControlOrMeta+a", "darwin")).toMatchObject({
      mask: 4,
      modifiers: [{ key: "Meta" }],
    });
    expect(parseChord("ControlOrMeta+a", "win32")).toMatchObject({
      mask: 2,
      modifiers: [{ key: "Control" }],
    });
  });
});
