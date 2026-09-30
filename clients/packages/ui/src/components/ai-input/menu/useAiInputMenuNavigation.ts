import { useLayoutEffect, useRef, type PointerEvent } from "react";
import type { AiInputMenuItem } from "../richText";

/** Selection follows input intent; scrolling is an output, never a new selection. */
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
    document.getElementById(activeOptionId)?.scrollIntoView?.({ block: "nearest" });
    // Source updates can move the same selected item to a different row.
  }, [activeOptionId, enabled, items]);

  return (event: PointerEvent<HTMLButtonElement>, index: number) => {
    if (!enabled || event.pointerType === "touch") return;
    const previous = pointerPositionRef.current;
    const { clientX: x, clientY: y } = event;
    if (
      previous?.x === x &&
      previous.y === y &&
      event.movementX === 0 &&
      event.movementY === 0
    )
      return;
    pointerPositionRef.current = { x, y };
    // Enter/leave can be caused by rows moving beneath a stationary pointer.
    // Only actual pointer movement can take selection back from the keyboard.
    const id = event.currentTarget.id;
    if (id === activeOptionId) return;
    pointerOptionRef.current = id;
    onHoverItem(index);
  };
}
