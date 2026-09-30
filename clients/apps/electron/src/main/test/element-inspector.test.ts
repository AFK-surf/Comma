// @vitest-environment jsdom

import type { BrowserSidebarInspectResult } from "@comma/native-bridge";
import { afterEach, describe, expect, it } from "vitest";
import { browserSidebarElementInspectorSource } from "../modules/browser-sidebar/element-inspector";

type SelectedInspection = Extract<BrowserSidebarInspectResult, { status: "selected" }>;

describe("browser sidebar element inspector", () => {
  afterEach(() => {
    globalThis.commaBrowserSidebarElementInspector?.cancel();
    globalThis.commaBrowserSidebarElementInspector = undefined;
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
});

async function selectElement(element: Element | null) {
  if (!element) throw new Error("Inspection fixture element is missing");
  const selection = globalThis.eval(
    browserSidebarElementInspectorSource
  ) as Promise<BrowserSidebarInspectResult>;
  element.dispatchEvent(
    new MouseEvent("click", { bubbles: true, cancelable: true, composed: true })
  );
  const result = await selection;
  if (result.status !== "selected") {
    throw new Error(`Expected selected inspection, received ${result.status}`);
  }
  return result as SelectedInspection;
}
