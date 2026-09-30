import { fitsCompactBox, type CompactBox, type PromptMeasurement } from "./measurement";

/**
 * Reads the rich prompt without collapsing it. Its scroll height is the
 * content height even while flex shrinks the compact row's box, and min-height
 * keeps it from reading shorter; nothing is written, so the read shares the
 * frame's single layout.
 *
 * Expanded, the draft folds back only when the compact box holds it in one
 * line, judged exactly as expansion was. That probe collapses the prompt, so
 * it runs only when the draft could fit: one line no wider than the compact
 * text box, or whenever that box was never seen.
 */
export function readRichPrompt(
  prompt: HTMLElement,
  {
    compact,
    compactBox,
    hasValue,
  }: {
    compact: boolean;
    compactBox: { current: CompactBox | undefined };
    hasValue: boolean;
  }
): PromptMeasurement {
  const bounds = prompt.getBoundingClientRect();
  const hasContent = hasValue || (prompt.textContent?.length ?? 0) > 0;
  const measurement: PromptMeasurement = {
    explicitHeight: false,
    fitsCompactLine: false,
    hasContent,
    height: prompt.scrollHeight,
    left: bounds.left,
    width: bounds.width,
  };
  if (compact) {
    if (bounds.width > 0) {
      compactBox.current = compactBoxOf(prompt, bounds.width);
    }
    return measurement;
  }
  const box = compactBox.current;
  if (hasContent && (!box || couldFitOneLine(prompt, box))) {
    measurement.fitsCompactLine = fitsCompactBox(prompt, box);
  }
  return measurement;
}

function compactBoxOf(prompt: HTMLElement, width: number): CompactBox {
  const style = getComputedStyle(prompt);
  return {
    padding: style.padding,
    textWidth:
      prompt.clientWidth -
      (parseFloat(style.paddingLeft) || 0) -
      (parseFloat(style.paddingRight) || 0),
    width,
  };
}

/**
 * A cheap pre-check from the current layout, conservative by construction:
 * it only rules out drafts whose own line boxes already span two lines or run
 * clearly wider than the compact text box. Client rects keep a line break's
 * zero-width box, which a bounding rect drops, so a draft ending on an empty
 * line reads as two lines. The slack of one line height covers trailing
 * spaces, which hang instead of wrapping. Anything else is settled by the
 * exact probe, so this check can never keep a draft from folding back.
 */
function couldFitOneLine(prompt: HTMLElement, box: CompactBox) {
  const range = prompt.ownerDocument.createRange();
  range.selectNodeContents(prompt);
  let top = Infinity;
  let bottom = -Infinity;
  let left = Infinity;
  let right = -Infinity;
  for (const rect of range.getClientRects()) {
    top = Math.min(top, rect.top);
    bottom = Math.max(bottom, rect.bottom);
    left = Math.min(left, rect.left);
    right = Math.max(right, rect.right);
  }
  const lineHeight = parseFloat(getComputedStyle(prompt).lineHeight) || 20;
  return bottom - top <= lineHeight * 1.5 && right - left <= box.textWidth + lineHeight;
}
