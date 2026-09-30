import { useCallback } from "react";
import type { RichEditorState } from "../state/useRichEditorState";

export type MenuBrowse = ReturnType<typeof useMenuBrowse>;

/** Stepping into a group's browse panel from the menu, and back out of it. */
export function useMenuBrowse({
  dismissedMenuSignatureRef,
  editorRef,
  setActiveMenu,
  triggerRangeRef,
}: RichEditorState) {
  /**
   * Steps into a group's browse panel. The trigger range stays live under
   * the panel: selecting there removes the same "@query" the list would
   * have, and stepping back puts the caret where it was.
   */
  const openBrowse = useCallback(
    (groupId: string) => {
      setActiveMenu((current) =>
        current ? { ...current, browseGroupId: groupId } : current
      );
    },
    [setActiveMenu]
  );

  const closeBrowse = useCallback(() => {
    setActiveMenu((current) =>
      current ? { ...current, browseGroupId: null } : current
    );
    const editor = editorRef.current;
    const range = triggerRangeRef.current;
    if (!editor) return;
    editor.focus();
    if (!range) return;
    const selection = window.getSelection();
    if (!selection) return;
    const caret = range.cloneRange();
    caret.collapse(false);
    selection.removeAllRanges();
    selection.addRange(caret);
  }, [editorRef, setActiveMenu, triggerRangeRef]);

  // The browse search field lost focus. Into the editor, the click there
  // re-reads the trigger on its own; anywhere else closes the menu the way
  // the editor's own blur does.
  const handleBrowseBlur = useCallback(
    (relatedTarget: Element | null) => {
      if (relatedTarget && editorRef.current?.contains(relatedTarget)) return;
      triggerRangeRef.current = null;
      dismissedMenuSignatureRef.current = null;
      setActiveMenu(null);
    },
    [dismissedMenuSignatureRef, editorRef, setActiveMenu, triggerRangeRef]
  );

  return { closeBrowse, handleBrowseBlur, openBrowse };
}
