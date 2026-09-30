import type { KeyboardEvent } from "react";
import { consumeWebKitImeConfirmation } from "../../../utils";
import type { ActiveMenu } from "../state/useRichEditorState";
import { stepIndex } from "../trigger-menu/menuTrigger";
import type { EditorEventContext } from "./editorEventContext";

/**
 * Keys while the trigger menu is open: arrows move through it (ArrowRight
 * into a "View more" row's browse panel), Enter or Tab picks, and Escape
 * dismisses it. Returns whether the key was the menu's.
 */
export function handleMenuKeyDown(
  event: KeyboardEvent<HTMLDivElement>,
  activeMenu: ActiveMenu,
  {
    browse: { openBrowse },
    selectItem,
    state: {
      activeIndex,
      dismissedMenuSignatureRef,
      lastCompositionEndAtRef,
      setActiveIndex,
      setActiveMenu,
      suppressedKeyUpRef,
      triggerRangeRef,
    },
  }: EditorEventContext
) {
  const hasItems = activeMenu.items.length > 0;
  const isLoading = activeMenu.groups.some((group) => group.status === "loading");
  if (hasItems && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
    event.preventDefault();
    suppressedKeyUpRef.current = event.key;
    setActiveIndex((current) =>
      stepIndex(current, event.key === "ArrowDown" ? 1 : -1, activeMenu.items.length)
    );
    return true;
  }

  // ArrowRight on a "View more" row steps into its browse panel — the
  // same gesture a submenu answers to. On any other row the caret is
  // the arrow's business, as ever.
  if (hasItems && event.key === "ArrowRight") {
    const item = activeMenu.items[activeIndex];
    if (item?.browseGroupId) {
      event.preventDefault();
      suppressedKeyUpRef.current = event.key;
      openBrowse(item.browseGroupId);
      return true;
    }
  }

  if (hasItems && (event.key === "Enter" || event.key === "Tab")) {
    event.preventDefault();
    suppressedKeyUpRef.current = event.key;
    if (consumeWebKitImeConfirmation(lastCompositionEndAtRef)) return true;
    const item = activeMenu.items[activeIndex] ?? activeMenu.items[0];
    if (item) selectItem(item);
    return true;
  }

  if (!hasItems && isLoading && (event.key === "Enter" || event.key === "Tab")) {
    event.preventDefault();
    suppressedKeyUpRef.current = event.key;
    return true;
  }

  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    suppressedKeyUpRef.current = event.key;
    dismissedMenuSignatureRef.current = activeMenu.signature;
    triggerRangeRef.current = null;
    setActiveMenu(null);
    return true;
  }
  return false;
}
