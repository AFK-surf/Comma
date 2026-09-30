/**
 * @vitest-environment jsdom
 */
import { describe, expect, it, vi } from "vitest";
import {
  copyTextToClipboard,
  openUrlInExternalBrowser,
  resolveHttpLinkFromEventTarget,
} from "../linkActions";

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

  it("opens web urls with window.open", async () => {
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null);
    await openUrlInExternalBrowser("https://example.com/docs");
    expect(openSpy).toHaveBeenCalledWith(
      "https://example.com/docs",
      "_blank",
      "noopener,noreferrer"
    );
    openSpy.mockRestore();
  });

  it("copies text through the clipboard API", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    await copyTextToClipboard("https://example.com/docs");
    expect(writeText).toHaveBeenCalledWith("https://example.com/docs");
  });
});
