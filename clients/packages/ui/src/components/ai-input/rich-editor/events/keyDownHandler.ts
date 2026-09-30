import type { KeyboardEvent, KeyboardEventHandler } from "react";
import { consumeWebKitImeConfirmation, isImeKeyEvent } from "../../../utils";
import {
  deleteAdjacentToken,
  insertTextAtSelection,
  removeTokenAndCollapseWhitespace,
} from "../dom/editing";
import { findTokenElement } from "../tokens/tokenElement";
import type { EditorEventContext } from "./editorEventContext";
import { handleMenuKeyDown } from "./menuKeyDown";

/**
 * The editor's keys, in precedence order: the edit menu shortcut, keys held
 * back while an IME composes, the selected token, the open menu, then Enter
 * to submit (Shift+Enter for a line break).
 */
export function createKeyDownHandler(
  context: EditorEventContext,
  onKeyDownProp: KeyboardEventHandler<HTMLDivElement> | undefined
) {
  const {
    commitEditor,
    disabled,
    editMenu: { openEditContextMenu },
    immutable,
    onSubmitRequest,
    readOnly,
    state: {
      activeMenu,
      activeTokenId,
      composingRef,
      lastCompositionEndAtRef,
      setActiveTokenId,
      suppressedKeyUpRef,
      triggerRangeRef,
    },
    tooltip: { hideTokenTooltip },
  } = context;

  return (event: KeyboardEvent<HTMLDivElement>) => {
    onKeyDownProp?.(event);
    if (event.defaultPrevented) return;

    if (
      !immutable &&
      (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))
    ) {
      event.preventDefault();
      suppressedKeyUpRef.current = event.key;
      openEditContextMenu(null);
      return;
    }

    const isComposing = composingRef.current || isImeKeyEvent(event.nativeEvent);

    if (isComposing) {
      if (event.key === "Enter") {
        event.preventDefault();
        suppressedKeyUpRef.current = event.key;
      }
      return;
    }

    if (disabled) {
      if (
        event.key === "Enter" ||
        event.key === " " ||
        event.key === "Delete" ||
        event.key === "Backspace"
      ) {
        event.preventDefault();
      }
      return;
    }

    if (readOnly) {
      if (event.key === "Enter") {
        event.preventDefault();
        suppressedKeyUpRef.current = event.key;
        if (!event.shiftKey) onSubmitRequest();
      } else if (
        event.key === " " ||
        event.key === "Delete" ||
        event.key === "Backspace"
      ) {
        event.preventDefault();
      }
      return;
    }

    if (activeTokenId) {
      if (event.key === "Delete" || event.key === "Backspace") {
        const tokenElement = findTokenElement(event.currentTarget, activeTokenId);
        if (tokenElement) {
          event.preventDefault();
          suppressedKeyUpRef.current = event.key;
          removeTokenAndCollapseWhitespace(tokenElement);
          setActiveTokenId(null);
          hideTokenTooltip(false);
          commitEditor();
          event.currentTarget.focus();
          return;
        }
      }

      if (event.key === "Escape") {
        event.preventDefault();
        suppressedKeyUpRef.current = event.key;
        setActiveTokenId(null);
        event.currentTarget.focus();
        return;
      }

      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        suppressedKeyUpRef.current = event.key;
        return;
      }
    }

    if (
      activeMenu &&
      triggerRangeRef.current &&
      handleMenuKeyDown(event, activeMenu, context)
    ) {
      return;
    }

    if (
      (event.key === "Backspace" || event.key === "Delete") &&
      deleteAdjacentToken(event.key)
    ) {
      event.preventDefault();
      suppressedKeyUpRef.current = event.key;
      commitEditor();
      return;
    }

    if (event.key !== "Enter") return;
    if (event.shiftKey) {
      event.preventDefault();
      suppressedKeyUpRef.current = event.key;
      insertTextAtSelection("\n");
      commitEditor();
      return;
    }
    if (consumeWebKitImeConfirmation(lastCompositionEndAtRef)) {
      event.preventDefault();
      suppressedKeyUpRef.current = event.key;
      return;
    }

    event.preventDefault();
    suppressedKeyUpRef.current = event.key;
    onSubmitRequest();
  };
}
