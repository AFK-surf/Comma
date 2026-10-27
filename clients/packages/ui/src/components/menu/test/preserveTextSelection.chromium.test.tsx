import "@comma/ui/styles.css";

import { afterEach, expect, it } from "vitest";
import {
  clearContextSelectionHighlight,
  CONTEXT_SELECTION_HIGHLIGHT,
  paintContextSelectionHighlight,
  snapshotLiveTextSelection,
} from "../preserveTextSelection";

// The preserved selection paints with the app's stylesheet in real Chromium:
// in the text it covers, and no other element styles it.

const transparent = "rgba(0, 0, 0, 0)";
const highlightBackground = (element: Element) =>
  getComputedStyle(element, `::highlight(${CONTEXT_SELECTION_HIGHLIGHT})`)
    .backgroundColor;

afterEach(() => {
  window.getSelection()?.removeAllRanges();
  document.body.replaceChildren();
});

it("paints the preserved selection where it was, and styles no element outside it", () => {
  const reply = document.createElement("article");
  reply.innerHTML = "<p>Agent <strong>reply</strong> text</p>";
  const elsewhere = document.createElement("p");
  elsewhere.textContent = "Another message";
  document.body.append(reply, elsewhere);
  const paragraph = reply.querySelector("p")!;
  const selection = window.getSelection()!;
  const range = document.createRange();
  range.selectNodeContents(paragraph);
  selection.removeAllRanges();
  selection.addRange(range);

  const highlight = paintContextSelectionHighlight(snapshotLiveTextSelection());
  expect(highlight).not.toBeNull();
  expect(highlightBackground(paragraph)).not.toBe(transparent);
  expect(highlightBackground(paragraph.querySelector("strong")!)).not.toBe(transparent);
  expect(highlightBackground(elsewhere)).toBe(transparent);

  clearContextSelectionHighlight(highlight);
  expect(highlightBackground(paragraph)).toBe(transparent);
});
