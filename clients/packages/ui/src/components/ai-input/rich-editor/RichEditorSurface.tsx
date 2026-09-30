/* oxlint-disable jsx-a11y/prefer-tag-over-role -- contenteditable and custom popup intentionally use textbox/listbox semantics. */
/* oxlint-disable jsx-a11y/role-supports-aria-props -- aria-expanded exposes the textbox's custom suggestion popup state. */
import { cx } from "../../utils";
import { aiInputRichEditor } from "../styles";
import type { EditorEventContext } from "./events/editorEventContext";
import { createInputHandlers } from "./events/inputHandlers";
import { createKeyDownHandler } from "./events/keyDownHandler";
import { createPointerHandlers } from "./events/pointerHandlers";
import { optionId } from "./trigger-menu/menuTrigger";
import type { AiInputRichEditorProps } from "./types";

export interface RichEditorSurfaceProps extends Pick<
  AiInputRichEditorProps,
  | "ariaLabel"
  | "className"
  | "editorProps"
  | "maxHeight"
  | "minHeight"
  | "placeholder"
  | "spellCheck"
> {
  context: EditorEventContext;
  isEditMenuOpen: boolean;
  required: boolean;
  setEditorRef: (node: HTMLDivElement | null) => void;
}

/**
 * The contenteditable textbox itself. The host's own handlers in editorProps
 * run first, and the editor's behavior follows them.
 */
export const RichEditorSurface = ({
  ariaLabel,
  className,
  context,
  editorProps,
  isEditMenuOpen,
  maxHeight,
  minHeight,
  placeholder,
  required,
  setEditorRef,
  spellCheck,
}: RichEditorSurfaceProps) => {
  const {
    onBeforeInput: onBeforeInputProp,
    onBlur: onBlurProp,
    onBlurCapture: onBlurCaptureProp,
    onClick: onClickProp,
    onCompositionEnd: onCompositionEndProp,
    onCompositionStart: onCompositionStartProp,
    onContextMenu: onContextMenuProp,
    onDrop: onDropProp,
    onFocus: onFocusProp,
    onInput: onInputProp,
    onKeyDown: onKeyDownProp,
    onKeyUp: onKeyUpProp,
    onMouseDown: onMouseDownProp,
    onMouseOut: onMouseOutProp,
    onMouseOver: onMouseOverProp,
    onPaste: onPasteProp,
    style: editorStyle,
    tabIndex: editorTabIndex,
    ...restEditorProps
  } = editorProps ?? {};
  const {
    currentExternalValue,
    disabled,
    immutable,
    readOnly,
    state: { activeIndex, activeMenu, menuId },
  } = context;
  const input = createInputHandlers(context, {
    onBeforeInputProp,
    onCompositionEndProp,
    onCompositionStartProp,
    onDropProp,
    onInputProp,
    onKeyUpProp,
    onPasteProp,
  });
  const pointer = createPointerHandlers(context, {
    onBlurCaptureProp,
    onBlurProp,
    onClickProp,
    onContextMenuProp,
    onFocusProp,
    onMouseDownProp,
    onMouseOutProp,
    onMouseOverProp,
  });

  return (
    <div
      {...restEditorProps}
      aria-activedescendant={
        activeMenu && !activeMenu.browseGroupId
          ? optionId(menuId, activeMenu.items[activeIndex]?.id)
          : undefined
      }
      aria-autocomplete="list"
      aria-controls={activeMenu ? menuId : undefined}
      aria-disabled={disabled || undefined}
      aria-expanded={activeMenu !== null && !immutable}
      aria-haspopup="listbox"
      aria-label={ariaLabel}
      aria-multiline="true"
      aria-readonly={readOnly || undefined}
      aria-required={required || undefined}
      className={cx(aiInputRichEditor, className)}
      contentEditable={!immutable}
      data-context-menu-open={isEditMenuOpen ? "true" : "false"}
      data-empty={String(currentExternalValue.plainText.length === 0)}
      data-placeholder={placeholder}
      onBlur={pointer.handleBlur}
      onClick={pointer.handleClick}
      onBeforeInput={input.handleBeforeInput}
      onCompositionEnd={input.handleCompositionEnd}
      onCompositionStart={input.handleCompositionStart}
      onContextMenu={pointer.handleContextMenu}
      onBlurCapture={pointer.handleBlurCapture}
      onDrop={input.handleDrop}
      onFocus={pointer.handleFocus}
      onInput={input.handleInput}
      onKeyDown={createKeyDownHandler(context, onKeyDownProp)}
      onKeyUp={input.handleKeyUp}
      onMouseDown={pointer.handleMouseDown}
      onMouseOut={pointer.handleMouseOut}
      onMouseOver={pointer.handleMouseOver}
      onPaste={input.handlePaste}
      ref={setEditorRef}
      role="textbox"
      spellCheck={spellCheck}
      style={{ ...editorStyle, minHeight, maxHeight }}
      suppressContentEditableWarning
      tabIndex={disabled ? -1 : (editorTabIndex ?? 0)}
    />
  );
};
