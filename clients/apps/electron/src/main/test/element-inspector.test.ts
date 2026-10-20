// @vitest-environment jsdom

import type { BrowserSidebarInspectResult } from "@comma/native-bridge";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { browserSidebarElementInspectorSource } from "../modules/browser-sidebar/element-inspector";

// The inspector's shadow root is closed; the tests keep it to see its outline.
let inspectorShadow: ShadowRoot | undefined;

// The file's timers run on the test's clock: a test moves it.
beforeEach(() => {
  vi.useFakeTimers();
  const attachShadow = HTMLElement.prototype.attachShadow;
  vi.spyOn(HTMLElement.prototype, "attachShadow").mockImplementation(function (
    this: HTMLElement,
    init: ShadowRootInit
  ) {
    inspectorShadow = attachShadow.call(this, init);
    return inspectorShadow;
  });
});

type SelectedInspection = Extract<BrowserSidebarInspectResult, { status: "selected" }>;

describe("browser sidebar element inspector", () => {
  afterEach(() => {
    globalThis.commaBrowserSidebarElementInspector?.cancel();
    globalThis.commaBrowserSidebarElementInspector = undefined;
    inspectorShadow = undefined;
    vi.restoreAllMocks();
    document.documentElement.replaceChildren(
      document.createElement("head"),
      document.createElement("body")
    );
  });

  it("serializes only allowlisted visible structure without form secrets", async () => {
    document.body.innerHTML = `
      <section
        id="account-card"
        class="card"
        aria-label="Account card"
        data-token="root-token-secret"
        onclick="recordClick('root-token-secret')"
      >
        Visible account details
        <!-- comment-secret -->
        <span title="Visible label" data-token="child-token-secret">Name</span>
        <input id="password" type="password" name="password" value="password-secret" />
        <input id="hidden-input" type="hidden" name="csrf" value="hidden-input-secret" />
        <input type="text" name="account" value="text-input-secret" />
        <textarea name="notes">textarea-secret</textarea>
        <span hidden>hidden-descendant-secret</span>
        <span aria-hidden="true">aria-hidden-secret</span>
        <span inert>inert-secret</span>
        <span style="display: none">styled-hidden-secret</span>
        <script>script-secret</script>
        <style>.style-secret { color: red; }</style>
      </section>
    `;

    const selected = await selectElement(document.querySelector("section"));
    expect(selected.element.attributes).toEqual({
      "aria-label": "Account card",
      class: "card",
      id: "account-card",
    });
    expect(selected.element.outerHTML).toContain("Visible account details");
    expect(selected.element.outerHTML).toContain('title="Visible label"');
    expect(selected.element.outerHTML).toContain('<input type="text" name="account">');
    expect(selected.element.outerHTML).toContain('<textarea name="notes"></textarea>');
    for (const privateValue of [
      "root-token-secret",
      "child-token-secret",
      "password-secret",
      "hidden-input-secret",
      "text-input-secret",
      "textarea-secret",
      "hidden-descendant-secret",
      "aria-hidden-secret",
      "inert-secret",
      "styled-hidden-secret",
      "comment-secret",
      "script-secret",
      "style-secret",
      "recordClick",
    ]) {
      expect(selected.element.outerHTML).not.toContain(privateValue);
    }
    expect(selected.element.outerHTML).not.toContain("data-token");
    expect(selected.element.outerHTML).not.toContain("onclick");

    const selectedPassword = await selectElement(document.querySelector("#password"));
    expect(selectedPassword.element).toMatchObject({
      attributes: { id: "password", name: "password", type: "password" },
      outerHTML: "",
      text: "",
    });

    const selectedHiddenInput = await selectElement(
      document.querySelector("#hidden-input")
    );
    expect(selectedHiddenInput.element).toMatchObject({ outerHTML: "", text: "" });
  });

  it("keeps sanitized element context bounded", async () => {
    document.body.innerHTML = `<article>${"visible ".repeat(1_000)}</article>`;

    const selected = await selectElement(document.querySelector("article"));

    expect(selected.element.outerHTML).toContain("...[truncated]");
    expect(selected.element.outerHTML?.length).toBeLessThanOrEqual(6_015);
  });

  it("draws no outline from the click until Main has captured the element", async () => {
    document.body.innerHTML = `<button id="target">Buy</button>`;
    const target = document.querySelector("#target");
    if (!target) throw new Error("Inspection fixture element is missing");
    vi.spyOn(target, "getBoundingClientRect").mockReturnValue(
      DOMRect.fromRect({ height: 20, width: 40, x: 10, y: 10 })
    );

    const selection = startInspection();
    target.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })
    );
    // A scroll before the capture leaves the outline off the page.
    globalThis.dispatchEvent(new Event("scroll"));
    expect(outlineDisplay()).toBe("none");
    expect((await settle(selection)).status).toBe("selected");
    globalThis.dispatchEvent(new Event("scroll"));
    expect(outlineDisplay()).toBe("none");

    globalThis.commaBrowserSidebarElementInspector?.highlight();
    expect(outlineDisplay()).toBe("block");
  });

  it("can still be cancelled while the selection waits for its frame", async () => {
    document.body.innerHTML = `<button id="target">Buy</button>`;
    const selection = startInspection();
    document
      .querySelector("#target")
      ?.dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })
      );

    globalThis.commaBrowserSidebarElementInspector?.cancel();

    expect(await settle(selection)).toEqual({ status: "cancelled" });
  });

  it("cancels on Escape while the selection waits for its frame", async () => {
    document.body.innerHTML = `<button id="target">Buy</button>`;
    const selection = startInspection();
    document
      .querySelector("#target")
      ?.dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })
      );

    document.dispatchEvent(
      new KeyboardEvent("keydown", { bubbles: true, key: "Escape" })
    );

    expect(await settle(selection)).toEqual({ status: "cancelled" });
  });

  it("reports where the selected element is now", async () => {
    document.body.innerHTML = `<button id="target">Buy</button>`;
    const target = document.querySelector("#target");
    if (!target) throw new Error("Inspection fixture element is missing");
    const place = vi
      .spyOn(target, "getBoundingClientRect")
      .mockReturnValue(DOMRect.fromRect({ height: 20, width: 40, x: 10, y: 10 }));
    const selected = await selectElement(target);
    expect(selected.element.rect).toEqual({ height: 20, width: 40, x: 10, y: 10 });

    // The page scrolls after the click.
    place.mockReturnValue(DOMRect.fromRect({ height: 20, width: 40, x: 10, y: -30 }));

    expect(globalThis.commaBrowserSidebarElementInspector?.rect()).toEqual({
      height: 20,
      width: 40,
      x: 10,
      y: -30,
    });
  });
});

function startInspection() {
  return globalThis.eval(
    browserSidebarElementInspectorSource
  ) as Promise<BrowserSidebarInspectResult>;
}

/** The selection once the frames it waits for have been painted. */
async function settle(selection: Promise<BrowserSidebarInspectResult>) {
  vi.advanceTimersToNextFrame();
  vi.advanceTimersToNextFrame();
  return await selection;
}

function outlineDisplay() {
  return inspectorShadow?.querySelector<HTMLElement>(".comma-inspector-box")?.style
    .display;
}

async function selectElement(element: Element | null) {
  if (!element) throw new Error("Inspection fixture element is missing");
  const selection = startInspection();
  element.dispatchEvent(
    new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })
  );
  const result = await settle(selection);
  if (result.status !== "selected") {
    throw new Error(`Expected selected inspection, received ${result.status}`);
  }
  return result as SelectedInspection;
}
