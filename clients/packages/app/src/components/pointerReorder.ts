import { spacing } from "@comma/ui";

/**
 * Shared geometry for pointer-driven row reordering. A list that lifts a row
 * under the pointer (the routine cards, the icon rail) translates it within
 * the band its siblings occupy and meets rubber-band resistance past it.
 */

/** Asymptotic ceiling for dragging past the row band, in px. */
export const pointerReorderOverdragCap = spacing.md;

// iOS rubber-band coefficient: initial resistance ~2x before the asymptote.
const overdragResistance = 0.55;

function dampenOverdrag(overshoot: number) {
  const cap = pointerReorderOverdragCap;
  return (1 - 1 / ((overshoot * overdragResistance) / cap + 1)) * cap;
}

// Translation past the list's row band meets rubber-band resistance instead of
// a hard stop. The overshoot must stay bounded: an unbounded translation
// extends a scroll viewport's scrollable overflow, which an edge auto-scroll
// then chases into an ever-growing empty region below the last row.
export function boundPointerReorderTranslation(
  translatedY: number,
  initialTops: ReadonlyMap<string, number>,
  startRowTop: number
) {
  let minTranslateY = 0;
  let maxTranslateY = 0;
  initialTops.forEach((top) => {
    const offset = top - startRowTop;
    minTranslateY = Math.min(minTranslateY, offset);
    maxTranslateY = Math.max(maxTranslateY, offset);
  });
  if (translatedY > maxTranslateY) {
    return maxTranslateY + dampenOverdrag(translatedY - maxTranslateY);
  }
  if (translatedY < minTranslateY) {
    return minTranslateY - dampenOverdrag(minTranslateY - translatedY);
  }
  return translatedY;
}

// Cancel only the WAAPI FLIP animations. getAnimations() also returns running
// CSS transitions (a lift fade on background, a shadow), and cancelling one of
// those snaps it to its end state mid-settle.
export function cancelFlipAnimations(row: HTMLElement) {
  for (const animation of row.getAnimations()) {
    if (typeof CSSTransition === "undefined" || !(animation instanceof CSSTransition)) {
      animation.cancel();
    }
  }
}

export function sameStringOrder(left: readonly string[], right: readonly string[]) {
  return (
    left.length === right.length && left.every((value, index) => value === right[index])
  );
}
