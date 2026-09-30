import type { BrowserSidebarInspectResult } from "@comma/native-bridge";
import { describe, expect, it } from "vitest";
import {
  buildBrowserElementInspectionMessage,
  parseBrowserElementInspectionMessage,
  stripBrowserElementInspectionContext,
} from "../browserElementInspection";

const inspection = {
  element: {
    attributes: { "aria-label": "Save", role: "button" },
    outerHTML: '<button aria-label="Save">Save</button>',
    rect: { height: 32, width: 80, x: 20.04, y: 40.06 },
    selector: "main > button",
    tagName: "button",
    text: "Save",
  },
  inspectionId: "inspection-1",
  page: { title: "Example", url: "https://example.com/docs" },
  status: "selected",
  userMessage: "Explain this control",
} satisfies Extract<BrowserSidebarInspectResult, { status: "selected" }>;

describe("browser element inspection context", () => {
  it("builds bounded model context while preserving the user's prompt", () => {
    const message = buildBrowserElementInspectionMessage(inspection);

    expect(message).toContain("Explain this control");
    expect(message).toContain('<browser-element-inspection id="inspection-1" />');
    expect(message).toContain("Page URL: https://example.com/docs");
    expect(message).toContain("Selector: main > button");
    expect(message).toContain("Attributes: aria-label=Save, role=button");
    expect(message).toContain("Bounding rect: x=20, y=40.1, width=80, height=32");
  });

  it("separates the visible prompt from structured inspection context", () => {
    const message = buildBrowserElementInspectionMessage(inspection);

    expect(stripBrowserElementInspectionContext(message)).toBe("Explain this control");
    expect(parseBrowserElementInspectionMessage(message)).toEqual({
      body: "Explain this control",
      context: {
        attributes: "aria-label=Save, role=button",
        elementText: "Save",
        inspectionId: "inspection-1",
        pageTitle: "Example",
        pageUrl: "https://example.com/docs",
        selector: "main > button",
        tagName: "button",
      },
    });
  });
});
