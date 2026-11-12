import { useLayoutEffect, useRef, type PointerEvent } from "react";
import type { AiInputMenuItem } from "../richText";

/**
 * Moves only the row's own list. `scrollIntoView` also scrolls every clipped pane around the
 * composer, which lifts the whole conversation when a menu reaches past the window's edge.
 */
function revealInList(row: HTMLElement | null) {
  const list = row?.closest('[data-slot="scroll-area-viewport"]');
  if (!row || !list) return;
  const bounds = list.getBoundingClientRect();
  const rowBounds = row.getBoundingClientRect();
  const rowTop = rowBounds.top - parseFloat(getComputedStyle(row).scrollMarginTop);
  if (rowTop < bounds.top) list.scrollTop -= bounds.top - rowTop;
  else if (rowBounds.bottom > bounds.bottom)
    list.scrollTop += rowBounds.bottom - bounds.bottom;
}

/**
 * Selection follows input intent; scrolling is an output, never a new selection.
 * The pointer handler answers whether the pointer itself moved.
 */
export function useAiInputMenuNavigation(
  activeOptionId: string | undefined,
  items: readonly AiInputMenuItem[],
  onHoverItem: (index: number) => void,
  enabled = true
) {
  const pointerOptionRef = useRef<string | null>(null);
  const pointerPositionRef = useRef<{ x: number; y: number } | null>(null);

  useLayoutEffect(() => {
    if (!enabled || !activeOptionId) return;
    if (pointerOptionRef.current === activeOptionId) return;
    pointerOptionRef.current = null;
    revealInList(document.getElementById(activeOptionId));
    // Source updates can move the same selected item to a different row.
  }, [activeOptionId, enabled, items]);

  return (event: PointerEvent<HTMLButtonElement>, index: number): boolean => {
    if (!enabled || event.pointerType === "touch") return false;
    const previous = pointerPositionRef.current;
    const { clientX: x, clientY: y } = event;
    if (
      previous?.x === x &&
      previous.y === y &&
      event.movementX === 0 &&
      event.movementY === 0
    )
      return false;
    pointerPositionRef.current = { x, y };
    // Enter/leave can be caused by rows moving beneath a stationary pointer.
    // Only actual pointer movement can take selection back from the keyboard.
    const id = event.currentTarget.id;
    if (id !== activeOptionId) {
      pointerOptionRef.current = id;
      onHoverItem(index);
    }
    return true;
  };
}
