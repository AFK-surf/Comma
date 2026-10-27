import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CONTEXT_SELECTION_HIGHLIGHT,
  CONTEXT_SELECTION_SCOPE_ATTRIBUTE,
  clearContextSelectionHighlight,
  paintContextSelectionHighlight,
  snapshotLiveTextSelection,
} from "../preserveTextSelection";
import { stubProperty } from "@comma/test-utils/stub-property";

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

/** The elements that hold a highlight's scope now, in document order. */
const marked = () => [
  ...document.querySelectorAll(`[${CONTEXT_SELECTION_SCOPE_ATTRIBUTE}]`),
];

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
    vi.stubGlobal("Highlight", FakeHighlight);
    stubProperty(CSS, "highlights", {
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

  it("marks the element around each highlight's ranges until the last highlight there is cleared", () => {
    class FakeHighlight {
      ranges: Range[];
      constructor(...ranges: Range[]) {
        this.ranges = ranges;
      }
    }
    vi.stubGlobal("Highlight", FakeHighlight);
    stubProperty(CSS, "highlights", {
      configurable: true,
      value: new Map<string, FakeHighlight>(),
    });
    const reply = document.createElement("article");
    reply.innerHTML = "<p>Agent <strong>reply</strong></p><p>Second paragraph</p>";
    document.body.append(reply);
    const [first, second] = [...reply.querySelectorAll("p")];
    // A range inside one text node: its paragraph holds the scope.
    const word = document.createRange();
    word.setStart(first!.firstChild!, 0);
    word.setEnd(first!.firstChild!, 5);
    // A range across both paragraphs: the reply around them holds it.
    const across = document.createRange();
    across.setStart(first!.firstChild!, 0);
    across.setEnd(second!.firstChild!, 6);

    const older = paintContextSelectionHighlight([word]);
    expect(marked()).toEqual([first]);
    const newer = paintContextSelectionHighlight([across, word]);
    expect(marked()).toEqual([reply, first]);

    // The older highlight was replaced in the registry: clearing it releases only its own hold.
    clearContextSelectionHighlight(older);
    expect(marked()).toEqual([reply, first]);
    clearContextSelectionHighlight(newer);
    expect(marked()).toEqual([]);
  });
});
