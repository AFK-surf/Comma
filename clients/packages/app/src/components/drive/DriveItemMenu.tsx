import type { MenuPointerOffsets } from "@comma/ui";
import { useCallback, useState } from "react";

/**
 * Right-click state shared by space rows, file rows, the rail, and their "…"
 * triggers: a pointer open carries offsets so the menu lands at the cursor,
 * a keyboard open leaves them null and the popover falls back to the anchor
 * edge.
 */
export function useDriveContextMenu() {
  const [isOpen, setIsOpen] = useState(false);
  const [pointerOffsets, setPointerOffsets] = useState<MenuPointerOffsets | null>(null);
  const open = useCallback((offsets: MenuPointerOffsets | null) => {
    setPointerOffsets(offsets);
    setIsOpen(true);
  }, []);
  return { isOpen, onOpenChange: setIsOpen, open, pointerOffsets };
}
