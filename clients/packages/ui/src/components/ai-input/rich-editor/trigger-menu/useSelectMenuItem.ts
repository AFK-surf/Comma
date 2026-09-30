import { useCallback, useRef } from "react";
import type { AiInputMenuItem, AiInputRichTokenSegment } from "../../richText";
import { placeCaretAfter } from "../dom/caret";
import { consumeLeadingBoundarySpace } from "../dom/editing";
import { createTokenElement, createTokenSpacer } from "../tokens/tokenElement";
import { nextTokenInstanceId } from "../tokens/tokenMap";
import type { RichEditorState } from "../state/useRichEditorState";

/**
 * Chooses a menu row: opens its browse panel, runs its action, inserts its
 * text, or replaces the trigger query with the item's token.
 */
export function useSelectMenuItem(
  state: RichEditorState,
  {
    commitEditor,
    immutable,
    menuOptionId,
    openBrowse,
    tokenTooltipId,
  }: {
    commitEditor: () => void;
    immutable: boolean;
    menuOptionId: (itemId: string | undefined) => string | undefined;
    openBrowse: (groupId: string) => void;
    tokenTooltipId: string;
  }
) {
  const {
    activeMenu,
    composingRef,
    dismissedMenuSignatureRef,
    editorRef,
    setActiveMenu,
    tokenMapRef,
    triggerRangeRef,
  } = state;
  const instanceCounterRef = useRef(0);

  return useCallback(
    (item: AiInputMenuItem) => {
      // Mid-composition the trigger range overlaps the IME's marked text;
      // mutating it would corrupt the composition, so selection waits for
      // compositionend (keyboard selection is already gated upstream).
      if (immutable || composingRef.current) return;
      const editor = editorRef.current;
      const range = triggerRangeRef.current;
      const menu = activeMenu;
      if (!editor || !range || !menu) return;

      if (item.browseGroupId) {
        openBrowse(item.browseGroupId);
        return;
      }

      if (item.action) {
        if (item.keepMenuOpen) {
          item.action();
          return;
        }
        // Action rows never leave a token behind: the trigger text (e.g.
        // "@add") is removed, the menu closes, and only then does the
        // action run so a picker opening cannot race the editor commit.
        range.deleteContents();
        triggerRangeRef.current = null;
        dismissedMenuSignatureRef.current = null;
        setActiveMenu(null);
        commitEditor();
        editor.focus();
        item.action();
        return;
      }

      if (item.insertText !== undefined) {
        range.deleteContents();
        const text = document.createTextNode(item.insertText);
        range.insertNode(text);
        range.setStartAfter(text);
        range.collapse(true);
        const selection = window.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
        triggerRangeRef.current = null;
        dismissedMenuSignatureRef.current = null;
        setActiveMenu(null);
        commitEditor();
        editor.focus();
        return;
      }

      const instanceId = nextTokenInstanceId(
        menu.registration.id,
        item.id,
        instanceCounterRef,
        tokenMapRef.current
      );
      // The pill reuses the glyph the reader just picked: capture the
      // option's rendered icon so the token stays recognizable in prose.
      const iconMarkup = document
        .getElementById(menuOptionId(item.id) ?? "")
        ?.querySelector(
          '[data-slot="ai-input-menu-item-icon"] > :first-child'
        )?.outerHTML;
      const token: AiInputRichTokenSegment = {
        type: "token",
        instanceId,
        menuId: menu.registration.id,
        itemId: item.id,
        trigger: menu.registration.trigger,
        label: item.tokenLabel ?? item.label,
        ...(item.description === undefined ? {} : { description: item.description }),
        ...(iconMarkup ? { iconMarkup } : {}),
        plainText: item.plainText ?? `${menu.registration.trigger}${item.id}`,
        ...(item.data === undefined ? {} : { data: item.data }),
      };
      tokenMapRef.current.set(instanceId, token);

      range.deleteContents();
      const hasLeadingBoundarySpace = consumeLeadingBoundarySpace(range);
      const tokenElement = createTokenElement(token, tokenTooltipId, false);
      const trailingSpacer = createTokenSpacer();
      const insertion = document.createDocumentFragment();
      if (hasLeadingBoundarySpace) insertion.append(createTokenSpacer());
      insertion.append(tokenElement, trailingSpacer);
      range.insertNode(insertion);
      placeCaretAfter(trailingSpacer);

      triggerRangeRef.current = null;
      dismissedMenuSignatureRef.current = null;
      setActiveMenu(null);
      commitEditor();
      editor.focus();
    },
    [
      activeMenu,
      commitEditor,
      composingRef,
      dismissedMenuSignatureRef,
      editorRef,
      immutable,
      menuOptionId,
      openBrowse,
      setActiveMenu,
      tokenMapRef,
      tokenTooltipId,
      triggerRangeRef,
    ]
  );
}
