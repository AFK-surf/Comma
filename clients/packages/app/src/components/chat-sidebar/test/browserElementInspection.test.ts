import type { BrowserSidebarInspectResult } from "@comma/native-bridge";
import { describe, expect, it } from "vitest";
import { browserElementSelection } from "../browserElementInspection";

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
  userMessage: "  Explain this control ",
} satisfies Extract<BrowserSidebarInspectResult, { status: "selected" }>;

describe("a picked element as a selection for the chat's next message", () => {
  it("keeps the person's note, the element and its page", () => {
    expect(browserElementSelection(inspection)).toEqual({
      note: "Explain this control",
      about: {
        kind: "element",
        inspectionId: "inspection-1",
        page: inspection.page,
        element: inspection.element,
      },
    });
  });

  it("carries the element's screenshot as its picture, and shows it in its tile", () => {
    const screenshot = new Uint8Array([137, 80, 78, 71]);
    const selection = browserElementSelection({ ...inspection, screenshot });

    expect(selection.picture).toEqual({ bytes: screenshot, type: "image/png" });
    expect(selection.thumbnail).toBe("data:image/png;base64,iVBORw==");
  });
});
