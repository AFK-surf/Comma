/**
 * @vitest-environment jsdom
 */
import { describe, expect, it } from "vitest";
import { resolveHttpLinkFromEventTarget } from "../linkActions";

describe("linkActions", () => {
  it("resolves http(s) anchors inside the root", () => {
    const root = document.createElement("div");
    const anchor = document.createElement("a");
    anchor.href = "https://example.com/docs";
    const span = document.createElement("span");
    span.textContent = "Open";
    anchor.appendChild(span);
    root.appendChild(anchor);
    document.body.appendChild(root);

    expect(resolveHttpLinkFromEventTarget(span, root)).toBe(anchor.href);
    expect(resolveHttpLinkFromEventTarget(root, root)).toBeNull();

    document.body.removeChild(root);
  });

  it("ignores non-http protocols", () => {
    const root = document.createElement("div");
    const anchor = document.createElement("a");
    anchor.href = "mailto:hello@example.com";
    root.appendChild(anchor);
    document.body.appendChild(root);

    expect(resolveHttpLinkFromEventTarget(anchor, root)).toBeNull();
    document.body.removeChild(root);
  });
});
