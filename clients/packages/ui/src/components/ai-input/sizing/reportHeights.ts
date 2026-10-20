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

/** What a host sizing itself also needs around the prompt; read with it. */
export interface ReportedExtras {
  attachmentHeight: number;
  rowGap: number;
}

/** Reads the extras only when a host listens for the heights. */
export function readReportedExtras(
  current: HeightReportTarget
): ReportedExtras | undefined {
  if (!current.onLayoutHeightChange && !current.onTextareaHeightChange)
    return undefined;
  const attachments = current.attachmentsRef.current;
  const shell = current.shellRef.current;
  return {
    attachmentHeight: attachments?.getBoundingClientRect().height ?? 0,
    rowGap:
      attachments && shell ? Number.parseFloat(getComputedStyle(shell).rowGap) || 0 : 0,
  };
}

/** Tells the host the prompt's and content's heights, once per change. */
export function reportHeights(
  current: HeightReportTarget,
  textareaHeight: number,
  extras: ReportedExtras | undefined,
  reported: { current: AiInputLayoutHeights | undefined }
) {
  if (!extras) return;
  const layout = {
    contentHeight: textareaHeight + extras.attachmentHeight + extras.rowGap,
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
