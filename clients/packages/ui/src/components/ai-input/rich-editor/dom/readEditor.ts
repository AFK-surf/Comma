import {
  createAiInputRichValue,
  type AiInputRichSegment,
  type AiInputRichTokenSegment,
  type AiInputRichValue,
} from "../../richText";

/** A read of the editor: its value, and where each text node starts in it. */
export interface EditorReadSnapshot {
  richValue: AiInputRichValue;
  textStarts: Map<Text, number>;
}

export function readRichValue(
  editor: ParentNode,
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  return readEditorSnapshot(editor, tokenMap).richValue;
}

export function readEditorSnapshot(
  editor: ParentNode,
  tokenMap: Map<string, AiInputRichTokenSegment>
): EditorReadSnapshot {
  const segments: AiInputRichSegment[] = [];
  const textStarts = new Map<Text, number>();
  const cursor = { plainTextLength: 0 };
  editor.childNodes.forEach((node) =>
    appendNodeSegments(node, segments, tokenMap, textStarts, cursor)
  );
  return { richValue: createAiInputRichValue(segments), textStarts };
}

function appendNodeSegments(
  node: Node,
  segments: AiInputRichSegment[],
  tokenMap: Map<string, AiInputRichTokenSegment>,
  textStarts: Map<Text, number>,
  cursor: { plainTextLength: number }
) {
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent ?? "";
    textStarts.set(node as Text, cursor.plainTextLength);
    segments.push({ type: "text", text });
    cursor.plainTextLength += text.length;
    return;
  }
  if (!(node instanceof HTMLElement)) return;

  const tokenId = node.dataset.aiInputToken;
  if (tokenId) {
    const token = tokenMap.get(tokenId);
    if (token) {
      segments.push(token);
      cursor.plainTextLength += token.plainText.length;
    }
    return;
  }
  if (node.dataset.aiInputTokenSpacer !== undefined) {
    segments.push({ type: "text", text: " " });
    cursor.plainTextLength += 1;
    return;
  }
  if (node.dataset.aiInputTrailingBreak !== undefined) return;
  if (node.tagName === "BR") {
    segments.push({ type: "text", text: "\n" });
    cursor.plainTextLength += 1;
    return;
  }

  const startsBlock =
    node !== node.parentElement?.firstChild && /^(DIV|P)$/u.test(node.tagName);
  if (startsBlock) {
    segments.push({ type: "text", text: "\n" });
    cursor.plainTextLength += 1;
  }
  node.childNodes.forEach((child) =>
    appendNodeSegments(child, segments, tokenMap, textStarts, cursor)
  );
}

export function readSelectedPlainText(
  editor: HTMLElement,
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return "";
  const range = selection.getRangeAt(0);
  if (!editor.contains(range.startContainer) || !editor.contains(range.endContainer)) {
    return "";
  }
  return readRichValue(range.cloneContents(), tokenMap).plainText;
}
