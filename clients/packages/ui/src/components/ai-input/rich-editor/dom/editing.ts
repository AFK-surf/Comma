import { placeCaretInText } from "./caret";

export function consumeLeadingBoundarySpace(range: Range) {
  const container = range.startContainer;
  const offset = range.startOffset;
  if (
    container.nodeType !== Node.TEXT_NODE ||
    offset === 0 ||
    (container as Text).data[offset - 1] !== " "
  ) {
    return false;
  }

  (container as Text).deleteData(offset - 1, 1);
  range.setStart(container, offset - 1);
  range.collapse(true);
  return true;
}

export function insertTextAtSelection(text: string) {
  const selection = window.getSelection();
  if (!selection?.rangeCount) return;
  const range = selection.getRangeAt(0);
  range.deleteContents();
  const textNode = document.createTextNode(text);
  range.insertNode(textNode);
  const previous =
    textNode.previousSibling?.nodeType === Node.TEXT_NODE
      ? (textNode.previousSibling as Text)
      : null;
  const next =
    textNode.nextSibling?.nodeType === Node.TEXT_NODE
      ? (textNode.nextSibling as Text)
      : null;
  const insertionOffset = previous?.data.length ?? 0;
  const caretOffset = insertionOffset + text.length;
  const mergedText = previous ?? textNode;

  if (previous) {
    previous.appendData(textNode.data);
    textNode.remove();
  }
  if (next) {
    mergedText.appendData(next.data);
    next.remove();
  }
  placeCaretInText(mergedText, caretOffset);
}

export function deleteSelectedContents(editor: HTMLElement) {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return;
  const range = selection.getRangeAt(0);
  if (!editor.contains(range.startContainer) || !editor.contains(range.endContainer)) {
    return;
  }
  range.deleteContents();
  selection.removeAllRanges();
  selection.addRange(range);
}

export function deleteAdjacentToken(key: "Backspace" | "Delete") {
  const selection = window.getSelection();
  if (!selection?.isCollapsed || !selection.anchorNode) return false;
  const anchor = selection.anchorNode;
  let candidate: Node | null = null;

  if (anchor.nodeType === Node.TEXT_NODE) {
    const length = anchor.textContent?.length ?? 0;
    if (key === "Backspace" && selection.anchorOffset === 0) {
      candidate = anchor.previousSibling;
    } else if (key === "Delete" && selection.anchorOffset === length) {
      candidate = anchor.nextSibling;
    }
  } else if (anchor instanceof HTMLElement) {
    const index = selection.anchorOffset + (key === "Backspace" ? -1 : 0);
    candidate = anchor.childNodes[index] ?? null;
  }

  if (
    candidate instanceof HTMLElement &&
    candidate.dataset.aiInputTokenSpacer !== undefined
  ) {
    candidate = key === "Backspace" ? candidate.previousSibling : candidate.nextSibling;
  }

  if (!(candidate instanceof HTMLElement) || !candidate.dataset.aiInputToken) {
    return false;
  }
  removeTokenAndCollapseWhitespace(candidate);
  return true;
}

export function removeTokenAndCollapseWhitespace(tokenElement: HTMLElement) {
  tokenElement.parentNode?.normalize();
  const previous = tokenElement.previousSibling;
  const tokenSpacer = tokenElement.nextSibling;
  const next =
    tokenSpacer instanceof HTMLElement &&
    tokenSpacer.dataset.aiInputTokenSpacer !== undefined
      ? tokenSpacer.nextSibling
      : tokenSpacer;
  const previousText =
    previous?.nodeType === Node.TEXT_NODE ? (previous as Text) : null;
  const nextText = next?.nodeType === Node.TEXT_NODE ? (next as Text) : null;

  tokenElement.remove();
  if (
    tokenSpacer instanceof HTMLElement &&
    tokenSpacer.dataset.aiInputTokenSpacer !== undefined
  ) {
    tokenSpacer.remove();
  }

  if (previousText && nextText) {
    if (previousText.data.endsWith(" ") && nextText.data.startsWith(" ")) {
      nextText.data = nextText.data.replace(/^ +/u, "");
    } else if (previousText.data.endsWith(" ") && /^[,.;:!?)]/u.test(nextText.data)) {
      previousText.data = previousText.data.replace(/ +$/u, "");
    }
    const caretOffset = previousText.data.length;
    previousText.appendData(nextText.data);
    nextText.remove();
    placeCaretInText(previousText, caretOffset);
    return;
  }

  if (nextText) {
    nextText.data = nextText.data.replace(/^ +/u, "");
    placeCaretInText(nextText, 0);
    return;
  }

  if (previousText) {
    previousText.data = previousText.data.replace(/ +$/u, "");
    placeCaretInText(previousText, previousText.data.length);
  }
}
