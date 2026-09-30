import type { AiInputRichTokenSegment } from "../../richText";
import { readRichValue } from "./readEditor";
import { TRAILING_LINE_BREAK_SELECTOR } from "./writeEditor";

export function selectAllEditorContents(editor: HTMLElement) {
  const selection = window.getSelection();
  if (!selection) return;
  const range = document.createRange();
  const trailingBreak =
    editor.lastChild instanceof HTMLElement &&
    editor.lastChild.dataset.aiInputTrailingBreak !== undefined
      ? editor.lastChild
      : null;
  if (trailingBreak) {
    range.setStart(editor, 0);
    range.setEndBefore(trailingBreak);
  } else {
    range.selectNodeContents(editor);
  }
  selection.removeAllRanges();
  selection.addRange(range);
}

export function placeSelectionAtPoint(editor: HTMLElement, x: number, y: number) {
  const caretDocument = document as Document & {
    caretPositionFromPoint?: (
      x: number,
      y: number
    ) => { offsetNode: Node; offset: number } | null;
    caretRangeFromPoint?: (x: number, y: number) => Range | null;
  };
  const position = caretDocument.caretPositionFromPoint?.(x, y);
  let range: Range | null = null;

  if (position) {
    range = document.createRange();
    range.setStart(position.offsetNode, position.offset);
    range.collapse(true);
  } else {
    range = caretDocument.caretRangeFromPoint?.(x, y) ?? null;
  }

  if (!range || !editor.contains(range.startContainer)) {
    const selection = window.getSelection();
    const currentRange = selection?.rangeCount ? selection.getRangeAt(0) : null;
    if (
      !currentRange ||
      !editor.contains(currentRange.startContainer) ||
      !editor.contains(currentRange.endContainer)
    ) {
      placeCaretAtEnd(editor);
    }
    return;
  }

  const startElement =
    range.startContainer instanceof Element
      ? range.startContainer
      : range.startContainer.parentElement;
  const token = startElement?.closest<HTMLElement>("[data-ai-input-token]");
  if (token && editor.contains(token)) {
    const bounds = token.getBoundingClientRect();
    const tokenBoundary = document.createRange();
    if (x < bounds.left + bounds.width / 2) tokenBoundary.setStartBefore(token);
    else tokenBoundary.setStartAfter(token);
    tokenBoundary.collapse(true);
    range = tokenBoundary;
  }

  const selection = window.getSelection();
  if (!selection) return;
  selection.removeAllRanges();
  selection.addRange(range);
}

export function placeCaretAfter(node: Node) {
  const selection = window.getSelection();
  if (!selection) return;
  const range = document.createRange();
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}

export function placeCaretAtEnd(editor: HTMLElement) {
  const selection = window.getSelection();
  if (!selection) return;
  const range = document.createRange();
  const trailingBreak =
    editor.lastChild instanceof HTMLElement &&
    editor.lastChild.dataset.aiInputTrailingBreak !== undefined
      ? editor.lastChild
      : null;
  if (trailingBreak) {
    range.setStartBefore(trailingBreak);
    range.collapse(true);
  } else {
    range.selectNodeContents(editor);
    range.collapse(false);
  }
  selection.removeAllRanges();
  selection.addRange(range);
}

export function revealTrailingCaret(
  editor: HTMLElement,
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  const trailingBreak = editor.querySelector<HTMLElement>(TRAILING_LINE_BREAK_SELECTOR);
  const selection = window.getSelection();
  if (
    !trailingBreak ||
    !selection?.isCollapsed ||
    selection.rangeCount === 0 ||
    !editor.contains(selection.anchorNode)
  ) {
    return;
  }

  const activeRange = selection.getRangeAt(0);
  const trailingBreakBoundary = document.createRange();
  trailingBreakBoundary.setStartBefore(trailingBreak);
  trailingBreakBoundary.collapse(true);
  if (
    activeRange.compareBoundaryPoints(Range.START_TO_START, trailingBreakBoundary) > 0
  ) {
    return;
  }

  const remainingRange = document.createRange();
  remainingRange.setStart(activeRange.endContainer, activeRange.endOffset);
  remainingRange.setEndBefore(trailingBreak);
  const remainingValue = readRichValue(remainingRange.cloneContents(), tokenMap);
  if (remainingValue.plainText.length > 0 || remainingValue.tokens.length > 0) return;

  editor.scrollTop = editor.scrollHeight;
}

export function placeCaretInText(text: Text, offset: number) {
  const selection = window.getSelection();
  if (!selection) return;
  const range = document.createRange();
  range.setStart(text, offset);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
}
