import { useCallback, useEffect, useRef, useState } from "react";
import { suspendHoverCards } from "../hover-card/HoverCard";
import { getMenuPointerOffsets, type MenuPointerOffsets } from "./pointerPosition";
import {
  clearContextSelectionHighlight,
  paintContextSelectionHighlight,
  snapshotLiveTextSelection,
} from "./preserveTextSelection";

export interface UseTextEditContextMenuStateOptions {
  isEnabled: boolean;
  onOpenChange?: (open: boolean) => void;
  preserveTextSelection?: boolean;
}

export const useTextEditContextMenuState = ({
  isEnabled,
  onOpenChange,
  preserveTextSelection = false,
}: UseTextEditContextMenuStateOptions) => {
  const isOpenRef = useRef(false);
  const selectionHighlightRef = useRef<Highlight | null>(null);
  const [isOpen, setIsOpen] = useState(false);
  const [shouldRestoreFocus, setShouldRestoreFocus] = useState(false);
  const [pointerOffsets, setPointerOffsets] = useState<MenuPointerOffsets | null>(null);
  const contextPointerTargetRef = useRef<Element | null>(null);
  const contextPointerUpAtRef = useRef<number | null>(null);
  const contextPointerUpTargetRef = useRef<EventTarget | null>(null);

  const captureLiveSelection = useCallback(() => {
    clearContextSelectionHighlight(selectionHighlightRef.current);
    selectionHighlightRef.current = preserveTextSelection
      ? paintContextSelectionHighlight(snapshotLiveTextSelection())
      : null;
  }, [preserveTextSelection]);

  const clearSelectionHighlight = useCallback(() => {
    clearContextSelectionHighlight(selectionHighlightRef.current);
    selectionHighlightRef.current = null;
  }, []);

  const handleOpenChange = useCallback(
    (open: boolean) => {
      if (isOpenRef.current === open) return false;

      if (!open) {
        const pointerUpAt = contextPointerUpAtRef.current;
        const pointerUpTarget = contextPointerUpTargetRef.current;
        const trigger = contextPointerTargetRef.current;
        const pointerUpIsOnTrigger =
          trigger &&
          pointerUpTarget instanceof Node &&
          (pointerUpTarget === trigger || trigger.contains(pointerUpTarget));
        if (
          pointerUpIsOnTrigger &&
          pointerUpAt !== null &&
          Date.now() - pointerUpAt < 100
        ) {
          // React Aria can treat the native right-button pointerup that
          // follows contextmenu as an outside dismissal. The menu was opened
          // by that same sequence, so keep it controlled-open until the user
          // interacts with the menu or outside it.
          return false;
        }
      }

      isOpenRef.current = open;
      if (!open) {
        setShouldRestoreFocus(true);
        clearSelectionHighlight();
      }
      setIsOpen(open);
      onOpenChange?.(open);
      return true;
    },
    [clearSelectionHighlight, onOpenChange]
  );

  useEffect(() => {
    if (isOpen && !isEnabled) {
      handleOpenChange(false);
    }
  }, [handleOpenChange, isEnabled, isOpen]);

  useEffect(() => clearSelectionHighlight, [clearSelectionHighlight]);

  useEffect(() => {
    if (!isOpen) return;
    return suspendHoverCards();
  }, [isOpen]);

  // React Aria's interact-outside dismissal ignores non-primary presses, so a
  // right click elsewhere would stack a second menu over this one. Capture
  // contextmenu at the document: with this menu open, a right click outside
  // every menu popover closes it — and the same event then travels on to open
  // whatever menu its target owns, so one gesture retargets. The click that
  // OPENS this menu can never self-dismiss here: this capture listener runs
  // before any React handler has called openAtPointer, while isOpen is still
  // false.
  useEffect(() => {
    const handleDocumentContextMenu = (event: MouseEvent) => {
      if (!isOpenRef.current) return;
      const target = event.target;
      if (target instanceof Element && target.closest('[data-slot="menu-popover"]')) {
        return;
      }
      handleOpenChange(false);
    };
    document.addEventListener("contextmenu", handleDocumentContextMenu, true);
    return () =>
      document.removeEventListener("contextmenu", handleDocumentContextMenu, true);
  }, [handleOpenChange]);

  useEffect(() => {
    const handlePointerDown = (event: PointerEvent) => {
      const trigger = contextPointerTargetRef.current;
      const target = event.target;
      if (
        !trigger ||
        !(target instanceof Node) ||
        (target !== trigger && !trigger.contains(target))
      ) {
        contextPointerUpAtRef.current = null;
        contextPointerUpTargetRef.current = null;
      }
    };
    const handlePointerUp = (event: PointerEvent) => {
      if (!isOpenRef.current) return;
      const trigger = contextPointerTargetRef.current;
      const target = event.target;
      if (
        trigger &&
        target instanceof Node &&
        (target === trigger || trigger.contains(target))
      ) {
        contextPointerUpAtRef.current = Date.now();
        contextPointerUpTargetRef.current = target;
      }
    };

    // The pointerup grace period above exists only to survive the opening
    // right-click's own pointerup. A keystroke is the user interacting with
    // the open menu, so it ends that window — otherwise a shortcut pressed
    // within 100ms of the right-click runs its action but cannot close the
    // menu, because handleOpenChange(false) is still being refused.
    const handleKeyDown = () => {
      if (!isOpenRef.current) return;
      contextPointerUpAtRef.current = null;
      contextPointerUpTargetRef.current = null;
    };

    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("pointerup", handlePointerUp, true);
    document.addEventListener("keydown", handleKeyDown, true);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown, true);
      document.removeEventListener("pointerup", handlePointerUp, true);
      document.removeEventListener("keydown", handleKeyDown, true);
    };
  }, []);

  const openAtPointer = useCallback(
    (
      trigger: Element,
      clientX: number,
      clientY: number,
      pointerTarget: Element = trigger
    ) => {
      if (!isEnabled) return;
      captureLiveSelection();
      setPointerOffsets(getMenuPointerOffsets(trigger, clientX, clientY));
      contextPointerTargetRef.current = pointerTarget;
      contextPointerUpAtRef.current = null;
      contextPointerUpTargetRef.current = null;
      handleOpenChange(true);
    },
    [captureLiveSelection, handleOpenChange, isEnabled]
  );

  const openFromKeyboard = useCallback(() => {
    if (!isEnabled) return;
    captureLiveSelection();
    setPointerOffsets(null);
    handleOpenChange(true);
  }, [captureLiveSelection, handleOpenChange, isEnabled]);

  return {
    isOpen,
    pointerOffsets,
    shouldRestoreFocus,
    setShouldRestoreFocus,
    handleOpenChange,
    openAtPointer,
    openFromKeyboard,
  };
};
