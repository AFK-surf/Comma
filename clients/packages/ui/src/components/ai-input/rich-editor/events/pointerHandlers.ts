import type { FocusEvent, HTMLAttributes, MouseEvent } from "react";
import { closestTokenElement } from "../tokens/tokenElement";
import type { EditorEventContext } from "./editorEventContext";

type DivAttributes = HTMLAttributes<HTMLDivElement>;

/**
 * Pointer and focus on the editor, mostly about its tokens: hovering or
 * focusing one shows its tooltip, clicking selects it, and leaving the
 * editor closes the menu. A right click opens the edit menu.
 */
export function createPointerHandlers(
  {
    editMenu: { openEditContextMenu },
    immutable,
    menu: { menuPanelRef, refreshMenu },
    state: {
      dismissedMenuSignatureRef,
      editorRef,
      setActiveMenu,
      setActiveTokenId,
      triggerRangeRef,
    },
    tooltip: { hideTokenTooltip, showTokenTooltip },
  }: EditorEventContext,
  {
    onBlurCaptureProp,
    onBlurProp,
    onClickProp,
    onContextMenuProp,
    onFocusProp,
    onMouseDownProp,
    onMouseOutProp,
    onMouseOverProp,
  }: {
    onBlurCaptureProp: DivAttributes["onBlurCapture"];
    onBlurProp: DivAttributes["onBlur"];
    onClickProp: DivAttributes["onClick"];
    onContextMenuProp: DivAttributes["onContextMenu"];
    onFocusProp: DivAttributes["onFocus"];
    onMouseDownProp: DivAttributes["onMouseDown"];
    onMouseOutProp: DivAttributes["onMouseOut"];
    onMouseOverProp: DivAttributes["onMouseOver"];
  }
) {
  const handleMouseOver = (event: MouseEvent<HTMLDivElement>) => {
    onMouseOverProp?.(event);
    showTokenTooltip(event.target, true);
  };

  const handleMouseOut = (event: MouseEvent<HTMLDivElement>) => {
    onMouseOutProp?.(event);
    const currentToken = closestTokenElement(event.target);
    const nextToken = closestTokenElement(event.relatedTarget);
    if (currentToken && currentToken !== nextToken) hideTokenTooltip(true);
  };

  const handleMouseDown = (event: MouseEvent<HTMLDivElement>) => {
    onMouseDownProp?.(event);
    if (event.defaultPrevented) return;
    if (!closestTokenElement(event.target)) return;
    event.preventDefault();
  };

  const handleClick = (event: MouseEvent<HTMLDivElement>) => {
    onClickProp?.(event);
    if (event.defaultPrevented) return;
    const tokenElement = closestTokenElement(event.target);
    if (!tokenElement) {
      setActiveTokenId(null);
      if (!immutable) {
        dismissedMenuSignatureRef.current = null;
        refreshMenu();
      }
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    if (immutable) return;
    setActiveTokenId(tokenElement.dataset.aiInputToken ?? null);
    tokenElement.focus();
  };

  const handleContextMenu = (event: MouseEvent<HTMLDivElement>) => {
    onContextMenuProp?.(event);
    if (event.defaultPrevented || immutable || !editorRef.current) return;
    event.preventDefault();
    openEditContextMenu({ clientX: event.clientX, clientY: event.clientY });
  };

  const handleBlur = (event: FocusEvent<HTMLDivElement>) => {
    onBlurProp?.(event);
    // Focus moving into the menu panel — its browse search field —
    // is the menu at work, not the menu being left.
    if (
      event.relatedTarget instanceof Node &&
      (event.currentTarget.contains(event.relatedTarget) ||
        menuPanelRef.current?.contains(event.relatedTarget))
    ) {
      return;
    }
    triggerRangeRef.current = null;
    dismissedMenuSignatureRef.current = null;
    setActiveMenu(null);
    setActiveTokenId(null);
  };

  const handleBlurCapture = (event: FocusEvent<HTMLDivElement>) => {
    onBlurCaptureProp?.(event);
    hideTokenTooltip(false);
  };

  const handleFocus = (event: FocusEvent<HTMLDivElement>) => {
    onFocusProp?.(event);
    const tokenElement = closestTokenElement(event.target);
    if (tokenElement && !immutable) {
      setActiveTokenId(tokenElement.dataset.aiInputToken ?? null);
      showTokenTooltip(tokenElement, false);
    }
  };

  return {
    handleBlur,
    handleBlurCapture,
    handleClick,
    handleContextMenu,
    handleFocus,
    handleMouseDown,
    handleMouseOut,
    handleMouseOver,
  };
}
