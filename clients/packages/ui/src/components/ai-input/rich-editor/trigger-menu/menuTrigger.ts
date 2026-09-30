import { findAiInputMenuMatch, type AiInputMenuRegistration } from "../../richText";
import { AI_INPUT_MENU_WIDTH_PX } from "../../styles";
import type { EditorReadSnapshot } from "../dom/readEditor";

export function findSelectionTrigger(
  editor: HTMLDivElement,
  registrations: readonly AiInputMenuRegistration[],
  snapshot: EditorReadSnapshot
) {
  const selection = window.getSelection();
  if (
    !selection?.isCollapsed ||
    !selection.anchorNode ||
    !editor.contains(selection.anchorNode)
  ) {
    return null;
  }

  const caret = resolveTextCaret(editor, selection.anchorNode, selection.anchorOffset);
  if (!caret) return null;
  const plainTextBeforeNode = snapshot.textStarts.get(caret.node);
  if (plainTextBeforeNode === undefined) return null;
  const plainTextBeforeCaret = snapshot.richValue.plainText.slice(
    0,
    plainTextBeforeNode + caret.offset
  );
  const match = findAiInputMenuMatch(
    plainTextBeforeCaret,
    registrations,
    snapshot.richValue.plainText
  );
  if (!match) return null;
  const localStart = match.start - plainTextBeforeNode;
  if (localStart < 0 || localStart > caret.offset) return null;

  const range = document.createRange();
  range.setStart(caret.node, localStart);
  range.setEnd(caret.node, caret.offset);
  return { ...match, range };
}

/**
 * Places the panel at the trigger's caret: left follows the trigger character
 * (clamped so the 353px panel stays inside the shell) and bottom sits on the
 * trigger line's top edge. Offsets are relative to the positioned shell's
 * padding box — the containing block of the absolutely positioned panel.
 */
export function menuAnchorPosition(editor: HTMLElement, range: Range) {
  const shell = editor.offsetParent;
  if (!(shell instanceof HTMLElement)) return null;

  const shellRect = shell.getBoundingClientRect();
  const rangeRect = range.getBoundingClientRect();
  if (shellRect.width === 0 && shellRect.height === 0) return null;

  const anchorLeft = rangeRect.left - shellRect.left - shell.clientLeft;
  const anchorTop = rangeRect.top - shellRect.top - shell.clientTop;
  const panelWidth = Math.min(AI_INPUT_MENU_WIDTH_PX, shell.clientWidth);
  const left = Math.max(0, Math.min(anchorLeft, shell.clientWidth - panelWidth));

  return {
    bottomOffset: shell.clientHeight - anchorTop,
    left,
    originX: Math.max(0, Math.min(anchorLeft - left, panelWidth)),
  };
}

export function menuTriggerSignature(
  {
    query,
    registration,
    start,
  }: {
    query: string;
    registration: AiInputMenuRegistration;
    start: number;
  },
  contentRevision: number
) {
  return JSON.stringify([registration.id, start, query, contentRevision]);
}

function resolveTextCaret(editor: HTMLDivElement, node: Node, offset: number) {
  if (node.nodeType === Node.TEXT_NODE) {
    return { node: node as Text, offset, text: node.textContent ?? "" };
  }

  if (node === editor && offset > 0) {
    const previous = editor.childNodes[offset - 1];
    if (previous?.nodeType === Node.TEXT_NODE) {
      return {
        node: previous as Text,
        offset: previous.textContent?.length ?? 0,
        text: previous.textContent ?? "",
      };
    }
  }

  return null;
}

export function stepIndex(current: number, delta: number, length: number) {
  return length <= 0 ? 0 : (current + delta + length) % length;
}

export function optionId(menuId: string, itemId: string | undefined) {
  return itemId
    ? `${menuId}-option-${itemId.replace(/[^a-z0-9_-]/giu, "-")}`
    : undefined;
}
