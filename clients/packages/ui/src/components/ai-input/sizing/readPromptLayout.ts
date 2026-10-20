import {
  nextSmallUsesDefaultLayout,
  trackNarrowest,
  type CompactBox,
} from "./measurement";
import { readCollapsedPrompt } from "./readCollapsedPrompt";
import { readRichPrompt } from "./readRichPrompt";
import {
  readReportedExtras,
  type HeightReportTarget,
  type ReportedExtras,
} from "./reportHeights";

export interface PromptLayoutInputs extends HeightReportTarget {
  hasValue: boolean;
  isSmall: boolean;
  measurementWidthMode: "rendered" | "narrowest";
  promptRef: { current: HTMLElement | null };
  smallUsesDefaultLayout: boolean;
  textareaMaxHeight: number;
  textareaMinHeight: number;
}

/** What one layout read decided: switch the small layout, or settle a height. */
export type PromptLayout =
  | { kind: "switch"; expanded: boolean; left: number; width: number }
  | {
      kind: "height";
      explicitHeight: boolean;
      extras: ReportedExtras | undefined;
      height: number;
      prompt: HTMLElement;
    };

/**
 * Reads the prompt's layout and decides what it needs; the caller commits the
 * decision. A textarea (or the narrowest-width mode) measures its collapsed
 * height by setting its height to 0 and restoring it, which leaves layout
 * dirty: the next read of the frame lays the page out once more.
 */
export function readPromptLayout(
  current: PromptLayoutInputs,
  boxes: {
    compactBox: { current: CompactBox | undefined };
    narrowestWidth: { current: number | undefined };
  }
): PromptLayout | undefined {
  const prompt = current.promptRef.current;
  if (!prompt) return undefined;
  const expanded = current.smallUsesDefaultLayout;
  const compact = current.isSmall && !expanded;
  const narrowest =
    current.measurementWidthMode === "narrowest"
      ? trackNarrowest(prompt, boxes.narrowestWidth)
      : undefined;
  const measurement =
    prompt instanceof HTMLTextAreaElement || narrowest !== undefined
      ? readCollapsedPrompt(prompt, {
          compact,
          compactBox: boxes.compactBox,
          expanded,
          hasValue: current.hasValue,
          narrowestWidth: narrowest,
        })
      : readRichPrompt(prompt, {
          compact,
          compactBox: boxes.compactBox,
          hasValue: current.hasValue,
        });
  const nextExpanded =
    current.isSmall && nextSmallUsesDefaultLayout(expanded, measurement);
  if (nextExpanded !== expanded) {
    return {
      kind: "switch",
      expanded: nextExpanded,
      left: measurement.left,
      width: measurement.width,
    };
  }
  return {
    kind: "height",
    explicitHeight: measurement.explicitHeight,
    extras: readReportedExtras(current),
    height: Math.min(
      Math.max(measurement.height, current.textareaMinHeight),
      current.textareaMaxHeight
    ),
    prompt,
  };
}
