import { useCallback, useEffect, useRef, useState } from "react";
import type {
  TextEditContextMenuDisabledActions,
  useTextEditContextMenuState,
} from "../../../menu";
import type { RichEditorState } from "../state/useRichEditorState";
import { useRichEditActions, type RichEditActionsOptions } from "./useRichEditActions";

export type RichEditMenu = ReturnType<typeof useRichEditMenu>;

/**
 * The rich prompt's Cut, Copy, Paste, and Select All menu. Opening it closes
 * the trigger menu and keeps the selection aside, to put back for each
 * action and once the menu hands focus back.
 */
export function useRichEditMenu(
  editMenu: ReturnType<typeof useTextEditContextMenuState>,
  state: RichEditorState,
  editActionsOptions: Omit<
    RichEditActionsOptions,
    "captureEditSelectionAfterAction" | "restoreEditSelection"
  >
) {
  const { immutable } = editActionsOptions;
  const {
    isOpen: isEditMenuOpen,
    shouldRestoreFocus: shouldRestoreEditMenuFocus,
    setShouldRestoreFocus: setShouldRestoreEditMenuFocus,
    openAtPointer: openEditMenuAtPointer,
    openFromKeyboard: openEditMenuFromKeyboard,
  } = editMenu;
  const { dismissedMenuSignatureRef, editorRef, setActiveMenu, triggerRangeRef } =
    state;
  const savedEditSelectionRef = useRef<Range | null>(null);
  const [editMenuDisabledActions, setEditMenuDisabledActions] =
    useState<TextEditContextMenuDisabledActions>({});

  const snapshotEditSelection = useCallback(() => {
    const editor = editorRef.current;
    const selection = window.getSelection();
    if (!editor || !selection?.rangeCount) {
      savedEditSelectionRef.current = null;
      return false;
    }
    const range = selection.getRangeAt(0);
    if (
      !editor.contains(range.startContainer) ||
      !editor.contains(range.endContainer)
    ) {
      savedEditSelectionRef.current = null;
      return false;
    }
    savedEditSelectionRef.current = range.cloneRange();
    return !selection.isCollapsed;
  }, [editorRef]);

  const restoreEditSelection = useCallback(() => {
    const editor = editorRef.current;
    const range = savedEditSelectionRef.current;
    if (!editor || !range) return false;
    try {
      if (
        !editor.contains(range.startContainer) ||
        !editor.contains(range.endContainer)
      ) {
        return false;
      }
      const selection = window.getSelection();
      if (!selection) return false;
      selection.removeAllRanges();
      selection.addRange(range);
      return true;
    } catch {
      return false;
    }
  }, [editorRef]);

  const captureEditSelectionAfterAction = useCallback(() => {
    snapshotEditSelection();
  }, [snapshotEditSelection]);

  const openEditContextMenu = useCallback(
    (pointer: { clientX: number; clientY: number } | null) => {
      const editor = editorRef.current;
      if (!editor || immutable) return;

      const hasSelection = snapshotEditSelection();
      setEditMenuDisabledActions({
        cut: !hasSelection,
        copy: !hasSelection,
        paste: false,
      });
      triggerRangeRef.current = null;
      dismissedMenuSignatureRef.current = null;
      setActiveMenu(null);
      editor.focus({ preventScroll: true });
      restoreEditSelection();

      if (pointer) {
        openEditMenuAtPointer(editor, pointer.clientX, pointer.clientY);
        return;
      }
      openEditMenuFromKeyboard();
    },
    [
      dismissedMenuSignatureRef,
      editorRef,
      immutable,
      openEditMenuAtPointer,
      openEditMenuFromKeyboard,
      restoreEditSelection,
      setActiveMenu,
      snapshotEditSelection,
      triggerRangeRef,
    ]
  );

  useEffect(() => {
    if (isEditMenuOpen || !shouldRestoreEditMenuFocus) return;
    editorRef.current?.focus({ preventScroll: true });
    restoreEditSelection();
    setShouldRestoreEditMenuFocus(false);
  }, [
    editorRef,
    isEditMenuOpen,
    restoreEditSelection,
    setShouldRestoreEditMenuFocus,
    shouldRestoreEditMenuFocus,
  ]);

  const handleEditMenuAction = useRichEditActions(state, {
    ...editActionsOptions,
    captureEditSelectionAfterAction,
    restoreEditSelection,
  });

  return { editMenuDisabledActions, handleEditMenuAction, openEditContextMenu };
}
