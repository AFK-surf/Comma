import { forwardRef, useCallback } from "react";
import { useTextEditContextMenuState } from "../../menu";
import { AiInputEditMenu } from "../AiInputEditMenu";
import { createPlainAiInputRichValue } from "../richText";
import { useRichEditMenu } from "./events/useRichEditMenu";
import { RichEditorSurface } from "./RichEditorSurface";
import { useCommitEditor } from "./state/useCommitEditor";
import { useEditorSync } from "./state/useEditorSync";
import { useRichEditorState } from "./state/useRichEditorState";
import { TokenTooltipOverlay } from "./tokens/TokenTooltipOverlay";
import { useTokenTooltip } from "./tokens/useTokenTooltip";
import { RichEditorMenu } from "./trigger-menu/RichEditorMenu";
import { useMenuBrowse } from "./trigger-menu/useMenuBrowse";
import { useSelectMenuItem } from "./trigger-menu/useSelectMenuItem";
import { useTriggerMenu } from "./trigger-menu/useTriggerMenu";
import type { AiInputRichEditorProps } from "./types";

/**
 * The shared rich prompt: a contenteditable textbox whose trigger characters
 * open menus and whose picks become tokens. Its hooks run in one fixed order;
 * the value written in from outside must settle before the menu re-reads it.
 */
export const AiInputRichEditor = forwardRef<HTMLDivElement, AiInputRichEditorProps>(
  function AiInputRichEditor(
    {
      value,
      richValue,
      richValueFromText,
      registrations,
      ariaLabel,
      clipboard,
      onPasteFilesFromMenu,
      placeholder,
      className,
      disabled = false,
      readOnly = false,
      required = false,
      maxLength,
      editorProps,
      spellCheck,
      minHeight,
      maxHeight,
      onEditorChange,
      onEditorLayoutChange,
      onSubmitRequest,
    },
    forwardedRef
  ) {
    const toRichValue = richValueFromText ?? createPlainAiInputRichValue;
    const state = useRichEditorState(richValue ?? toRichValue(value));
    const tooltip = useTokenTooltip(state.tokenMapRef);
    const immutable = disabled || readOnly;
    const editMenuState = useTextEditContextMenuState({ isEnabled: !immutable });
    const effectiveMaxLength =
      maxLength === undefined ? undefined : Math.max(0, maxLength);
    const { editorRef } = state;

    const setEditorRef = useCallback(
      (node: HTMLDivElement | null) => {
        editorRef.current = node;
        if (typeof forwardedRef === "function") forwardedRef(node);
        else if (forwardedRef) forwardedRef.current = node;
      },
      [editorRef, forwardedRef]
    );

    const currentExternalValue = useEditorSync(state, tooltip, {
      immutable,
      richValue,
      toRichValue,
      value,
    });
    const menu = useTriggerMenu(state, { immutable, registrations });
    const browse = useMenuBrowse(state);
    const commitEditor = useCommitEditor(state, tooltip, {
      effectiveMaxLength,
      immutable,
      onEditorChange,
      refreshMenu: menu.refreshMenu,
      richValue,
    });
    const selectItem = useSelectMenuItem(state, {
      commitEditor,
      immutable,
      menuOptionId: menu.menuOptionId,
      openBrowse: browse.openBrowse,
      tokenTooltipId: tooltip.tokenTooltipId,
    });
    const editMenu = useRichEditMenu(editMenuState, state, {
      clipboard,
      commitEditor,
      immutable,
      onPasteFilesFromMenu,
    });

    return (
      <>
        <RichEditorSurface
          ariaLabel={ariaLabel}
          className={className}
          context={{
            browse,
            commitEditor,
            currentExternalValue,
            disabled,
            editMenu,
            effectiveMaxLength,
            immutable,
            menu,
            onEditorLayoutChange,
            onSubmitRequest,
            readOnly,
            selectItem,
            state,
            tooltip,
          }}
          editorProps={editorProps}
          isEditMenuOpen={editMenuState.isOpen}
          maxHeight={maxHeight}
          minHeight={minHeight}
          placeholder={placeholder}
          required={required}
          setEditorRef={setEditorRef}
          spellCheck={spellCheck}
        />
        <TokenTooltipOverlay tooltip={tooltip} />
        <RichEditorMenu
          browse={browse}
          immutable={immutable}
          menu={menu}
          selectItem={selectItem}
          state={state}
        />
        <AiInputEditMenu
          disabledActions={editMenu.editMenuDisabledActions}
          menu={editMenuState}
          onAction={editMenu.handleEditMenuAction}
          triggerRef={editorRef}
        />
      </>
    );
  }
);
