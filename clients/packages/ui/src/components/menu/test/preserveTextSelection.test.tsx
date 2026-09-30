import { afterEach, describe, expect, it } from "vitest";
import {
  CONTEXT_SELECTION_HIGHLIGHT,
  clearContextSelectionHighlight,
  paintContextSelectionHighlight,
  snapshotLiveTextSelection,
} from "../preserveTextSelection";

const selectText = (element: HTMLElement, endOffset: number) => {
  const textNode = element.firstChild;
  if (!textNode) throw new Error("expected a text node");
  const range = document.createRange();
  range.setStart(textNode, 0);
  range.setEnd(textNode, endOffset);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
  return range;
};

describe("preserveTextSelection", () => {
  afterEach(() => {
    window.getSelection()?.removeAllRanges();
    CSS.highlights?.delete(CONTEXT_SELECTION_HIGHLIGHT);
    document.body.replaceChildren();
  });

  it("snapshots a live range without changing the selection", () => {
    const paragraph = document.createElement("p");
    paragraph.textContent = "Agent reply";
    document.body.append(paragraph);
    const selectedRange = selectText(paragraph, 5);

    const ranges = snapshotLiveTextSelection();
    expect(ranges).toHaveLength(1);
    expect(ranges[0]).not.toBe(selectedRange);
    expect(window.getSelection()?.toString()).toBe("Agent");
  });

  it("returns an empty snapshot for a collapsed selection", () => {
    expect(snapshotLiveTextSelection()).toEqual([]);
  });

  it("does not paint ranges whose nodes are disconnected", () => {
    const detached = document.createElement("p");
    detached.textContent = "Agent";
    const range = document.createRange();
    range.selectNodeContents(detached);

    expect(paintContextSelectionHighlight([range])).toBeNull();
  });

  it("paints and clears a CSS highlight when the API exists", () => {
    class FakeHighlight {
      ranges: Range[];
      constructor(...ranges: Range[]) {
        this.ranges = ranges;
      }
    }
    const highlights = new Map<string, FakeHighlight>();
    Object.defineProperty(window, "Highlight", {
      configurable: true,
      value: FakeHighlight,
    });
    Object.defineProperty(CSS, "highlights", {
      configurable: true,
      value: highlights,
    });

    const paragraph = document.createElement("p");
    paragraph.textContent = "Agent";
    document.body.append(paragraph);
    const range = document.createRange();
    range.selectNodeContents(paragraph);

    const first = paintContextSelectionHighlight([range]);
    const second = paintContextSelectionHighlight([range]);
    expect(first).toBeInstanceOf(FakeHighlight);
    expect(second).toBeInstanceOf(FakeHighlight);
    expect(highlights.get(CONTEXT_SELECTION_HIGHLIGHT)).toBe(second);

    clearContextSelectionHighlight(null);
    expect(highlights.get(CONTEXT_SELECTION_HIGHLIGHT)).toBe(second);

    clearContextSelectionHighlight(first);
    expect(highlights.get(CONTEXT_SELECTION_HIGHLIGHT)).toBe(second);

    clearContextSelectionHighlight(second);
    expect(highlights.has(CONTEXT_SELECTION_HIGHLIGHT)).toBe(false);
  });
});
