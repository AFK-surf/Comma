import { useCallback, useEffect, useRef, useState } from "react";
import type {
  TextEditContextMenuDisabledActions,
  useTextEditContextMenuState,
} from "../../menu";
import {
  useTextareaEditActions,
  type TextareaEditActionsOptions,
  type TextareaSelection,
} from "./useTextareaEditActions";

export interface TextareaEditMenuOptions extends Omit<
  TextareaEditActionsOptions,
  "restoreTextareaSelection" | "savedTextareaSelectionRef" | "textareaRef"
> {
  /** Plain prompts only: the rich editor runs its own menu. */
  isEnabled: boolean;
}

export type TextareaEditMenu = ReturnType<typeof useTextareaEditMenu>;

/**
 * The plain prompt's Cut, Copy, Paste, and Select All menu. Opening it moves
 * focus into the menu, so the textarea's selection is kept aside and put back
 * for each action and when the menu closes. The open state comes in from the
 * composer, which creates it ahead of its other hooks.
 */
export function useTextareaEditMenu(
  textareaEditMenu: ReturnType<typeof useTextEditContextMenuState>,
  { isEnabled: textareaEditMenuEnabled, ...editActionsOptions }: TextareaEditMenuOptions
) {
  const {
    isOpen: isTextareaEditMenuOpen,
    shouldRestoreFocus: shouldRestoreTextareaEditMenuFocus,
    setShouldRestoreFocus: setShouldRestoreTextareaEditMenuFocus,
    openAtPointer: openTextareaEditMenuAtPointer,
    openFromKeyboard: openTextareaEditMenuFromKeyboard,
  } = textareaEditMenu;
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const savedTextareaSelectionRef = useRef<TextareaSelection | null>(null);
  const [textareaEditMenuDisabledActions, setTextareaEditMenuDisabledActions] =
    useState<TextEditContextMenuDisabledActions>({});

  const snapshotTextareaSelection = useCallback(() => {
    const textarea = textareaRef.current;
    if (!textarea) {
      savedTextareaSelectionRef.current = null;
      return false;
    }
    savedTextareaSelectionRef.current = {
      start: textarea.selectionStart,
      end: textarea.selectionEnd,
    };
    return textarea.selectionStart !== textarea.selectionEnd;
  }, []);

  const restoreTextareaSelection = useCallback(() => {
    const textarea = textareaRef.current;
    const saved = savedTextareaSelectionRef.current;
    if (!textarea || !saved) return;
    textarea.setSelectionRange(saved.start, saved.end);
  }, []);

  const openTextareaEditContextMenu = useCallback(
    (pointer: { clientX: number; clientY: number } | null) => {
      const textarea = textareaRef.current;
      if (!textarea || !textareaEditMenuEnabled) return;

      const hasSelection = snapshotTextareaSelection();
      setTextareaEditMenuDisabledActions({
        cut: !hasSelection,
        copy: !hasSelection,
        paste: false,
      });
      textarea.focus({ preventScroll: true });
      restoreTextareaSelection();

      if (pointer) {
        openTextareaEditMenuAtPointer(textarea, pointer.clientX, pointer.clientY);
        return;
      }
      openTextareaEditMenuFromKeyboard();
    },
    [
      openTextareaEditMenuAtPointer,
      openTextareaEditMenuFromKeyboard,
      restoreTextareaSelection,
      snapshotTextareaSelection,
      textareaEditMenuEnabled,
    ]
  );

  useEffect(() => {
    if (isTextareaEditMenuOpen || !shouldRestoreTextareaEditMenuFocus) return;
    textareaRef.current?.focus({ preventScroll: true });
    restoreTextareaSelection();
    setShouldRestoreTextareaEditMenuFocus(false);
  }, [
    isTextareaEditMenuOpen,
    restoreTextareaSelection,
    setShouldRestoreTextareaEditMenuFocus,
    shouldRestoreTextareaEditMenuFocus,
  ]);

  const handleTextareaEditMenuAction = useTextareaEditActions({
    ...editActionsOptions,
    restoreTextareaSelection,
    savedTextareaSelectionRef,
    textareaRef,
  });

  return {
    handleTextareaEditMenuAction,
    isEnabled: textareaEditMenuEnabled,
    menu: textareaEditMenu,
    openTextareaEditContextMenu,
    textareaEditMenuDisabledActions,
    textareaRef,
  };
}
