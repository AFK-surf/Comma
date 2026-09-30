import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { isReducedMotionEnabled } from "../../../../tokens";
import { filterAiInputMenuGroups, type AiInputMenuRegistration } from "../../richText";
import { readEditorSnapshot, type EditorReadSnapshot } from "../dom/readEditor";
import type { ActiveMenu, RichEditorState } from "../state/useRichEditorState";
import {
  findSelectionTrigger,
  menuAnchorPosition,
  menuTriggerSignature,
  optionId,
} from "./menuTrigger";

export type TriggerMenu = ReturnType<typeof useTriggerMenu>;

/**
 * The menu a trigger character opens: found from the caret after each edit,
 * and kept live as its async sources settle.
 */
export function useTriggerMenu(
  state: RichEditorState,
  {
    immutable,
    registrations,
  }: { immutable: boolean; registrations: readonly AiInputMenuRegistration[] }
) {
  const {
    activeIndex,
    activeMenu,
    dismissedMenuSignatureRef,
    editorContentRevisionRef,
    editorRef,
    editorSnapshotRef,
    menuId,
    setActiveIndex,
    setActiveMenu,
    tokenMapRef,
    triggerRangeRef,
  } = state;
  // Holds the just-closed menu briefly so the panel can fade out in place.
  const [closingMenu, setClosingMenu] = useState<ActiveMenu | null>(null);
  const previousMenuRef = useRef<ActiveMenu | null>(null);
  const menuPanelRef = useRef<HTMLDivElement | null>(null);
  const menuOptionId = useCallback(
    (itemId: string | undefined) => optionId(menuId, itemId),
    [menuId]
  );

  // Async menu sources replace their registration object when they settle.
  // Keep an already-open trigger/query live without requiring another editor
  // event, while preserving the selected item when it still exists.
  useLayoutEffect(() => {
    if (!activeMenu) return;
    const registration = registrations.find(
      (candidate) => candidate.id === activeMenu.registration.id
    );
    if (registration === activeMenu.registration) return;
    if (!registration) {
      triggerRangeRef.current = null;
      setActiveMenu(null);
      return;
    }

    const groups = filterAiInputMenuGroups(registration, activeMenu.query);
    const items = groups.flatMap((group) => [...group.items]);
    const previousItemId = activeMenu.items[activeIndex]?.id;
    const preservedIndex = previousItemId
      ? items.findIndex((item) => item.id === previousItemId)
      : -1;

    setActiveMenu({ ...activeMenu, groups, items, registration });
    setActiveIndex(preservedIndex >= 0 ? preservedIndex : 0);
  }, [
    activeIndex,
    activeMenu,
    registrations,
    setActiveIndex,
    setActiveMenu,
    triggerRangeRef,
  ]);

  const sourceQueryChanged = activeMenu?.registration.onQueryChange;
  const sourceQuery = activeMenu && !activeMenu.browseGroupId ? activeMenu.query : null;
  useEffect(() => {
    sourceQueryChanged?.(sourceQuery);
    return () => sourceQueryChanged?.(null);
  }, [sourceQueryChanged, sourceQuery]);

  // The exit ghost: when the menu closes, keep its last render mounted just
  // long enough for the 80ms fade (a generous timer stands in for
  // transitionend on an already-inert node). Opening again replaces the
  // ghost immediately, and reduced motion skips it entirely.
  useEffect(() => {
    const previous = previousMenuRef.current;
    previousMenuRef.current = activeMenu;
    if (activeMenu || !previous || isReducedMotionEnabled()) {
      setClosingMenu(null);
      return undefined;
    }

    setClosingMenu(previous);
    const timer = window.setTimeout(() => setClosingMenu(null), 160);
    return () => window.clearTimeout(timer);
  }, [activeMenu]);

  const refreshMenu = useCallback(
    (preferredSnapshot?: EditorReadSnapshot) => {
      const editor = editorRef.current;
      if (!editor || immutable) {
        triggerRangeRef.current = null;
        setActiveMenu(null);
        return;
      }

      const snapshot =
        preferredSnapshot ??
        editorSnapshotRef.current ??
        readEditorSnapshot(editor, tokenMapRef.current);
      editorSnapshotRef.current = snapshot;
      const selectionTrigger = findSelectionTrigger(editor, registrations, snapshot);
      if (!selectionTrigger) {
        triggerRangeRef.current = null;
        dismissedMenuSignatureRef.current = null;
        setActiveMenu(null);
        return;
      }

      const signature = menuTriggerSignature(
        selectionTrigger,
        editorContentRevisionRef.current
      );
      if (dismissedMenuSignatureRef.current === signature) {
        triggerRangeRef.current = null;
        setActiveMenu(null);
        return;
      }
      dismissedMenuSignatureRef.current = null;

      const groups = filterAiInputMenuGroups(
        selectionTrigger.registration,
        selectionTrigger.query
      );
      const items = groups.flatMap((group) => [...group.items]);

      triggerRangeRef.current = selectionTrigger.range;
      const previousItemId =
        activeMenu?.signature === signature
          ? activeMenu.items[activeIndex]?.id
          : undefined;
      setActiveMenu({
        registration: selectionTrigger.registration,
        groups,
        items,
        query: selectionTrigger.query,
        signature,
        position: menuAnchorPosition(editor, selectionTrigger.range),
        browseGroupId: null,
      });
      const preservedIndex = previousItemId
        ? items.findIndex((item) => item.id === previousItemId)
        : -1;
      setActiveIndex(preservedIndex >= 0 ? preservedIndex : 0);
    },
    [
      activeIndex,
      activeMenu,
      dismissedMenuSignatureRef,
      editorContentRevisionRef,
      editorRef,
      editorSnapshotRef,
      immutable,
      registrations,
      setActiveIndex,
      setActiveMenu,
      tokenMapRef,
      triggerRangeRef,
    ]
  );

  return { closingMenu, menuOptionId, menuPanelRef, refreshMenu };
}
