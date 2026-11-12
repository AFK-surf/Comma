import { useLayoutEffect, useRef, type RefObject } from "react";

// Marks a surface kept mounted while hidden; commaSurfacePause.css holds its loops paused.
export const COMMA_SURFACE_PAUSED_ATTRIBUTE = "data-comma-surface-paused";
export const COMMA_SURFACE_PAUSED_SELECTOR = `[${COMMA_SURFACE_PAUSED_ATTRIBUTE}='true']`;

export function isCommaSurfacePaused(element: Element | null | undefined) {
  return Boolean(element?.closest(COMMA_SURFACE_PAUSED_SELECTOR));
}

/**
 * Holds a selection inside a surface aside while the surface is paused. The
 * browser skips a paused surface's style and layout, but not around a
 * selection in it: a caret left in Home's composer made every frame of the
 * page in front cost time in proportion to Home (13-24 ms at 200 mounted
 * turns). The selection is taken in the commit that pauses the surface and
 * given back in the commit that shows it, unless the member selected
 * something else meanwhile, so a draft's caret stays where it was.
 */
export function useSelectionAsideWhilePaused(
  surfaceRef: RefObject<HTMLElement | null>,
  paused: boolean
) {
  const aside = useRef<Range[] | null>(null);
  useLayoutEffect(() => {
    const surface = surfaceRef.current;
    const selection = window.getSelection();
    if (!surface || !selection) return;
    if (paused) {
      const ranges: Range[] = [];
      for (let index = 0; index < selection.rangeCount; index += 1) {
        const range = selection.getRangeAt(index);
        if (surface.contains(range.commonAncestorContainer)) {
          ranges.push(range.cloneRange());
        }
      }
      if (ranges.length === 0) return;
      aside.current = ranges;
      selection.removeAllRanges();
      return;
    }
    const held = aside.current;
    aside.current = null;
    if (!held || selection.rangeCount > 0) return;
    for (const range of held) {
      if (range.startContainer.isConnected && range.endContainer.isConnected) {
        selection.addRange(range);
      }
    }
  }, [paused, surfaceRef]);
}
