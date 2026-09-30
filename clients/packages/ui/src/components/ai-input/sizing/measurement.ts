import { AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX } from "../styles";

/** What one layout read says about the prompt. */
export interface PromptMeasurement {
  /** The prompt was measured collapsed and needs its height set. */
  explicitHeight: boolean;
  /** Expanded only: the draft fits one line of the compact row. */
  fitsCompactLine: boolean;
  hasContent: boolean;
  height: number;
  left: number;
  width: number;
}

export interface CompactBox {
  padding: string;
  /** The width left for text once the box's padding is taken. */
  textWidth: number;
  width: number;
}

/**
 * The content height of a prompt that cannot size itself: a textarea, or a
 * rich prompt measured at a narrower width than it renders at. Collapsing the
 * box exposes its content height; every override is put back before the
 * frame paints, along with the scroll offset the collapse clamps away.
 * Transitions are left alone: the prompt never transitions its box (its
 * container animates the size), and overriding them would cancel the slide
 * running on the prompt's transform.
 */
export function collapsedScrollHeight(
  element: HTMLElement,
  width?: number | undefined,
  padding?: string | undefined
) {
  const { style } = element;
  const previous = {
    height: style.height,
    maxHeight: style.maxHeight,
    minHeight: style.minHeight,
    padding: style.padding,
    width: style.width,
  };
  const { scrollTop } = element;
  if (width !== undefined) style.width = `${width}px`;
  if (padding !== undefined) style.padding = padding;
  style.setProperty("height", "0px", "important");
  style.setProperty("min-height", "0px", "important");
  style.setProperty("max-height", "none", "important");
  const { scrollHeight } = element;
  style.height = previous.height;
  style.minHeight = previous.minHeight;
  style.maxHeight = previous.maxHeight;
  style.width = previous.width;
  style.padding = previous.padding;
  element.scrollTop = scrollTop;
  return scrollHeight;
}

/** The small composer expands for a second line and folds back for one. */
export function nextSmallUsesDefaultLayout(
  expanded: boolean,
  measurement: PromptMeasurement
) {
  if (!measurement.hasContent) return false;
  return expanded
    ? !measurement.fitsCompactLine
    : measurement.height > AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX + 0.5;
}

/**
 * Whether the compact box holds the prompt in one line; the fold-back test.
 * A prompt that had no width while compact never saw that box, so its own
 * box stands in, and a wrong guess only costs a switch that measures again.
 */
export function fitsCompactBox(prompt: HTMLElement, box: CompactBox | undefined) {
  return (
    collapsedScrollHeight(prompt, box?.width, box?.padding) <=
    AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX
  );
}

/** The narrowest width seen, while the prompt renders wider than it. */
export function trackNarrowest(
  prompt: HTMLElement,
  narrowest: { current: number | undefined }
) {
  const width = prompt.getBoundingClientRect().width;
  if (width > 0) narrowest.current = Math.min(narrowest.current ?? width, width);
  return narrowest.current !== undefined && narrowest.current < width - 0.5
    ? narrowest.current
    : undefined;
}
