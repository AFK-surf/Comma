import type {
  AiInputRichSegment,
  AiInputRichTokenSegment,
  AiInputRichValue,
} from "../../richText";
import { createTokenElement, createTokenSpacer } from "../tokens/tokenElement";

export const TRAILING_LINE_BREAK_SELECTOR = "[data-ai-input-trailing-break]";

export function writeRichValue(
  editor: HTMLElement,
  richValue: AiInputRichValue,
  tokenMap: Map<string, AiInputRichTokenSegment>,
  tooltipId: string,
  disabled: boolean
) {
  tokenMap.clear();
  const fragment = document.createDocumentFragment();
  richValue.segments.forEach((segment, index) => {
    if (segment.type === "text") {
      appendTextWithTokenBoundarySpacing(
        fragment,
        segment.text,
        richValue.segments[index - 1],
        richValue.segments[index + 1]
      );
      return;
    }
    tokenMap.set(segment.instanceId, segment);
    fragment.append(createTokenElement(segment, tooltipId, disabled));
  });
  editor.replaceChildren(fragment);
  syncTrailingLineBreak(editor, richValue.plainText);
}

export function syncTrailingLineBreak(editor: HTMLElement, plainText: string) {
  const trailingBreaks = Array.from(
    editor.querySelectorAll<HTMLElement>(TRAILING_LINE_BREAK_SELECTOR)
  );
  const existingTrailingBreak = trailingBreaks.shift();
  trailingBreaks.forEach((node) => {
    node.remove();
  });
  if (!plainText.endsWith("\n")) {
    existingTrailingBreak?.remove();
    return;
  }

  const trailingBreak = existingTrailingBreak ?? document.createElement("br");
  trailingBreak.dataset.aiInputTrailingBreak = "";
  trailingBreak.setAttribute("aria-hidden", "true");
  if (editor.lastChild !== trailingBreak) editor.append(trailingBreak);
}

function appendTextWithTokenBoundarySpacing(
  fragment: DocumentFragment,
  text: string,
  previous: AiInputRichSegment | undefined,
  next: AiInputRichSegment | undefined
) {
  let remaining = text;
  if (previous?.type === "token" && remaining.startsWith(" ")) {
    fragment.append(createTokenSpacer());
    remaining = remaining.slice(1);
  }

  const hasTrailingBoundarySpace = next?.type === "token" && remaining.endsWith(" ");
  if (hasTrailingBoundarySpace) remaining = remaining.slice(0, -1);
  if (remaining) fragment.append(document.createTextNode(remaining));
  if (hasTrailingBoundarySpace) fragment.append(createTokenSpacer());
}
