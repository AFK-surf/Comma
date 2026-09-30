import type { MouseEvent, RefObject } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { cx } from "../../utils";
import { AiInputEditMenu } from "../AiInputEditMenu";
import type { FilePaste } from "../files/useFilePaste";
import { AiInputRichEditor } from "../rich-editor/AiInputRichEditor";
import type { AiInputMenuRegistration } from "../richText";
import type { useAiInputAutoSize } from "../sizing/useAiInputAutoSize";
import {
  aiInputSmallPromptMotion,
  aiInputSmallTextarea,
  aiInputTextarea,
} from "../styles";
import type {
  AiInputClipboard,
  AiInputNativeAttributes,
  AiInputProps,
  ForwardedAiInputProps,
} from "../types";
import type { VoiceRecording } from "../voice/useVoiceRecording";
import { getRichEditorProps } from "./richEditorProps";
import { usePromptKeyboard } from "./usePromptKeyboard";
import type { PromptValue } from "./usePromptValue";
import type { TextareaEditMenu } from "./useTextareaEditMenu";

/** What the composer leaves to the prompt: its own options and native attributes. */
export type AiInputPromptNativeProps = AiInputNativeAttributes &
  Pick<AiInputProps, "richEditorClassName" | "textareaClassName">;

export interface AiInputPromptProps extends ForwardedAiInputProps<
  "maxLength" | "richValue" | "richValueFromText"
> {
  clipboard: AiInputClipboard;
  currentValue: string;
  disabled: boolean;
  filePaste: FilePaste;
  isSmall: boolean;
  menuRegistrations: readonly AiInputMenuRegistration[];
  nativeProps: AiInputPromptNativeProps;
  promptRef: RefObject<HTMLElement | null>;
  promptValue: PromptValue;
  readOnly: boolean;
  sizing: ReturnType<typeof useAiInputAutoSize>;
  textareaEdit: TextareaEditMenu;
  usesRichText: boolean;
  voice: VoiceRecording;
}

/**
 * The prompt itself: the shared rich editor, or a native textarea with the
 * composer's edit menu in place of the native one.
 */
export const AiInputPrompt = ({
  clipboard,
  currentValue,
  disabled,
  filePaste: { handlePaste, pasteFilesFromMenu },
  isSmall,
  maxLength,
  menuRegistrations,
  nativeProps: {
    onCompositionEnd,
    onCompositionStart,
    onKeyDown,
    placeholder,
    required = false,
    richEditorClassName,
    spellCheck,
    textareaClassName,
    ...textareaProps
  },
  promptRef,
  promptValue,
  readOnly,
  richValue,
  richValueFromText,
  sizing: { measureEdit, textareaMaxHeight, textareaMinHeight, usesCompactLayout },
  textareaEdit,
  usesRichText,
  voice,
}: AiInputPromptProps) => {
  const messages = useCommaMessages();
  const keyboard = usePromptKeyboard({
    editMenuEnabled: textareaEdit.isEnabled,
    onCompositionEnd,
    onCompositionStart,
    onKeyDown,
    onSubmit: promptValue.handleSubmit,
    openEditMenu: textareaEdit.openTextareaEditContextMenu,
    voice,
  });
  const promptPlaceholder =
    placeholder ??
    (isSmall ? messages.ui_ai_small_prompt() : messages.ui_ai_default_prompt());
  const promptLabel = textareaProps["aria-label"] ?? messages.ui_ai_prompt();
  const promptClassName = cx(
    isSmall && aiInputSmallPromptMotion,
    usesCompactLayout && aiInputSmallTextarea,
    textareaClassName
  );

  const handleTextareaContextMenu = (event: MouseEvent<HTMLTextAreaElement>) => {
    textareaProps.onContextMenu?.(event);
    if (event.defaultPrevented || !textareaEdit.isEnabled) return;
    event.preventDefault();
    textareaEdit.openTextareaEditContextMenu({
      clientX: event.clientX,
      clientY: event.clientY,
    });
  };

  if (usesRichText) {
    return (
      <AiInputRichEditor
        ariaLabel={promptLabel}
        className={cx(promptClassName, richEditorClassName)}
        clipboard={clipboard}
        onPasteFilesFromMenu={pasteFilesFromMenu}
        disabled={disabled}
        editorProps={getRichEditorProps({
          ...textareaProps,
          onCompositionEnd,
          onCompositionStart,
          onKeyDown: keyboard.handleRichKeyDown,
          onPaste: handlePaste,
        })}
        maxLength={maxLength}
        maxHeight={textareaMaxHeight}
        minHeight={textareaMinHeight}
        onEditorChange={promptValue.handleEditorChange}
        onEditorLayoutChange={measureEdit}
        onSubmitRequest={promptValue.handleSubmit}
        placeholder={promptPlaceholder}
        readOnly={readOnly}
        ref={(element) => {
          promptRef.current = element;
        }}
        registrations={menuRegistrations}
        richValue={richValue}
        richValueFromText={richValueFromText}
        spellCheck={spellCheck}
        required={required}
        value={currentValue}
      />
    );
  }

  return (
    <>
      <textarea
        {...textareaProps}
        aria-label={promptLabel}
        className={cx(aiInputTextarea, promptClassName)}
        data-context-menu-open={textareaEdit.menu.isOpen ? "true" : "false"}
        disabled={disabled}
        maxLength={maxLength}
        onChange={promptValue.handleChange}
        onCompositionEnd={keyboard.handleCompositionEnd}
        onCompositionStart={keyboard.handleCompositionStart}
        onContextMenu={handleTextareaContextMenu}
        onKeyDown={keyboard.handleKeyDown}
        onPaste={handlePaste}
        placeholder={promptPlaceholder}
        readOnly={readOnly}
        ref={(element) => {
          promptRef.current = element;
          textareaEdit.textareaRef.current = element;
        }}
        rows={1}
        spellCheck={spellCheck}
        required={required}
        style={{
          minHeight: textareaMinHeight,
          maxHeight: textareaMaxHeight,
        }}
        value={currentValue}
      />
      <AiInputEditMenu
        disabledActions={textareaEdit.textareaEditMenuDisabledActions}
        menu={textareaEdit.menu}
        onAction={textareaEdit.handleTextareaEditMenuAction}
        triggerRef={textareaEdit.textareaRef}
      />
    </>
  );
};
