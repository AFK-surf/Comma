import type { RefObject } from "react";

export interface AiInputLayoutHeights {
  contentHeight: number;
  textareaHeight: number;
}

/** Where the prompt's heights are read from and who hears about them. */
export interface HeightReportTarget {
  attachmentsRef: RefObject<HTMLElement | null>;
  onLayoutHeightChange?: ((layout: AiInputLayoutHeights) => void) | undefined;
  onTextareaHeightChange?: ((height: number) => void) | undefined;
  shellRef: RefObject<HTMLElement | null>;
}

/** Tells the host the prompt's and content's heights, once per change. */
export function reportHeights(
  current: HeightReportTarget,
  textareaHeight: number,
  reported: { current: AiInputLayoutHeights | undefined }
) {
  if (!current.onLayoutHeightChange && !current.onTextareaHeightChange) return;
  const attachments = current.attachmentsRef.current;
  const shell = current.shellRef.current;
  const attachmentHeight = attachments?.getBoundingClientRect().height ?? 0;
  const rowGap =
    attachments && shell ? Number.parseFloat(getComputedStyle(shell).rowGap) || 0 : 0;
  const layout = {
    contentHeight: textareaHeight + attachmentHeight + rowGap,
    textareaHeight,
  };
  const previous = reported.current;
  if (
    previous?.textareaHeight === layout.textareaHeight &&
    previous.contentHeight === layout.contentHeight
  ) {
    return;
  }
  reported.current = layout;
  current.onTextareaHeightChange?.(textareaHeight);
  current.onLayoutHeightChange?.(layout);
}
