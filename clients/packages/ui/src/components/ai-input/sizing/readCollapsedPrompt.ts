import { AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX } from "../styles";
import {
  collapsedScrollHeight,
  type CompactBox,
  type PromptMeasurement,
} from "./measurement";

/**
 * Measures by collapsing the prompt, at the narrowest width seen when asked.
 * An expanded small prompt is also probed in the compact box it came from, so
 * a draft at the wrap point cannot alternate between one and two lines.
 */
export function readCollapsedPrompt(
  prompt: HTMLElement,
  {
    compact,
    compactBox,
    expanded,
    hasValue,
    narrowestWidth,
  }: {
    compact: boolean;
    compactBox: { current: CompactBox | undefined };
    expanded: boolean;
    hasValue: boolean;
    /** Set only when heights follow the narrowest width seen. */
    narrowestWidth: number | undefined;
  }
): PromptMeasurement {
  const bounds = prompt.getBoundingClientRect();
  const width = narrowestWidth ?? (bounds.width > 0 ? bounds.width : undefined);
  if (compact && width !== undefined) {
    const style = getComputedStyle(prompt);
    compactBox.current = {
      padding: style.padding,
      textWidth:
        width -
        (parseFloat(style.paddingLeft) || 0) -
        (parseFloat(style.paddingRight) || 0),
      width,
    };
  }
  const height = collapsedScrollHeight(prompt, width);
  const box = compactBox.current;
  const compactHeight =
    expanded && box ? collapsedScrollHeight(prompt, box.width, box.padding) : height;
  const hasContent =
    hasValue ||
    (prompt instanceof HTMLTextAreaElement
      ? prompt.value.length > 0
      : (prompt.textContent?.length ?? 0) > 0);
  return {
    explicitHeight: true,
    fitsCompactLine: compactHeight <= AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX,
    hasContent,
    height,
    left: bounds.left,
    width: bounds.width,
  };
}
