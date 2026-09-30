import { useLayoutEffect, useRef, useState } from "react";
import { useTextEditContextMenuState } from "../../menu";
import { useAttachmentPreview } from "../attachments/useAttachmentPreview";
import { useFileDrop } from "../files/useFileDrop";
import { useFilePaste } from "../files/useFilePaste";
import { AiInputPrompt } from "../prompt/AiInputPrompt";
import { usePromptValue } from "../prompt/usePromptValue";
import { useTextareaEditMenu } from "../prompt/useTextareaEditMenu";
import { useAiInputAutoSize } from "../sizing/useAiInputAutoSize";
import { AiInputToolbar } from "../toolbar/AiInputToolbar";
import { useAttachTooltip } from "../toolbar/useAttachTooltip";
import type { AiInputProps } from "../types";
import { useVoiceRecording } from "../voice/useVoiceRecording";
import { AiInputShell } from "./AiInputShell";
import { browserAiInputClipboard } from "./browserClipboard";

/**
 * The composer. Its hooks keep one fixed order: the prompt's measurements
 * read the layout that useAiInputAutoSize synced just before them.
 */
export const AiInput = ({
  clipboard = browserAiInputClipboard,
  size = "default",
  value,
  defaultValue = "",
  onChange,
  onValueChange,
  onSubmit,
  richText = false,
  menuRegistrations = [],
  richValue,
  richValueFromText,
  onRichValueChange,
  onRichSubmit,
  attachments = [],
  onAttachmentRemove,
  onAttachPress,
  onDropFiles,
  onPasteFiles,
  dropPlaceholder,
  onAccessPress,
  onVoicePress,
  onVoiceCancel,
  onVoiceConfirm,
  accessLabel,
  attachLabel,
  voiceLabel,
  voiceLevel,
  sendLabel,
  showAccessButton = false,
  showAttachButton = true,
  showVoiceButton = true,
  toolbarLeading,
  toolbarTrailing,
  textareaMaxHeight: textareaMaxHeightOverride,
  textareaMeasurementWidthMode = "rendered",
  textareaMinHeight: textareaMinHeightOverride,
  onLayoutHeightChange,
  onTextareaHeightChange,
  submitDisabled = false,
  submitPending = false,
  disabled = false,
  readOnly = false,
  maxLength,
  className,
  onPaste,
  autoFocus,
  ...promptProps
}: AiInputProps) => {
  const [draftValue, setDraftValue] = useState(defaultValue);
  const usesRichText =
    richText || richValue !== undefined || menuRegistrations.length > 0;
  const currentValue = richValue?.plainText ?? value ?? draftValue;
  const isSmall = size === "small";
  const promptRef = useRef<HTMLElement>(null);
  const textareaMenuEnabled = !usesRichText && !(disabled || readOnly);
  const textareaMenu = useTextEditContextMenuState({ isEnabled: textareaMenuEnabled });
  const attachmentsRef = useRef<HTMLDivElement>(null);
  const preview = useAttachmentPreview(attachments);
  const shellRef = useRef<HTMLDivElement>(null);
  const sizing = useAiInputAutoSize({
    attachmentsRef,
    hasValue: currentValue.length > 0,
    isSmall,
    maxHeightOverride: textareaMaxHeightOverride,
    measurementWidthMode: textareaMeasurementWidthMode,
    minHeightOverride: textareaMinHeightOverride,
    onLayoutHeightChange,
    onTextareaHeightChange,
    promptRef,
    shellRef,
  });
  const attachTooltip = useAttachTooltip(attachments, onAttachPress, showAttachButton);
  const drop = useFileDrop(onDropFiles);
  const promptValue = usePromptValue({
    attachments,
    currentValue,
    disabled,
    onChange,
    onRichSubmit,
    onRichValueChange,
    onSubmit,
    onValueChange,
    richValue,
    richValueFromText,
    setDraftValue,
    sizing,
    submitDisabled,
    submitPending,
    usesRichText,
    value,
  });
  useLayoutEffect(() => {
    if (autoFocus) promptRef.current?.focus();
  }, [autoFocus, usesRichText]);
  const voice = useVoiceRecording({
    disabled,
    onVoiceCancel,
    onVoiceConfirm,
    onVoicePress,
    promptRef,
    readOnly,
    showVoiceButton,
    submitPending,
  });
  const filePaste = useFilePaste({ clipboard, onPaste, onPasteFiles });
  const textareaEdit = useTextareaEditMenu(textareaMenu, {
    clipboard,
    isEnabled: textareaMenuEnabled,
    maxLength,
    onChange,
    onValueChange,
    pasteFilesFromMenu: filePaste.pasteFilesFromMenu,
    requestMeasure: sizing.requestMeasure,
    setDraftValue,
    value,
  });

  return (
    <AiInputShell
      attachments={attachments}
      attachmentsRef={attachmentsRef}
      className={className}
      disabled={disabled}
      drop={drop}
      dropPlaceholder={dropPlaceholder}
      isSmall={isSmall}
      isVoiceRecording={voice.isVoiceRecording}
      onAttachmentRemove={onAttachmentRemove}
      preview={preview}
      prompt={
        <AiInputPrompt
          clipboard={clipboard}
          currentValue={currentValue}
          disabled={disabled}
          filePaste={filePaste}
          isSmall={isSmall}
          maxLength={maxLength}
          menuRegistrations={menuRegistrations}
          nativeProps={promptProps}
          promptRef={promptRef}
          promptValue={promptValue}
          readOnly={readOnly}
          richValue={richValue}
          richValueFromText={richValueFromText}
          sizing={sizing}
          textareaEdit={textareaEdit}
          usesRichText={usesRichText}
          voice={voice}
        />
      }
      shellRef={shellRef}
      showAccessButton={showAccessButton}
      sizing={sizing}
      toolbar={
        <AiInputToolbar
          accessLabel={accessLabel}
          attachLabel={attachLabel}
          attachTooltip={attachTooltip}
          disabled={disabled}
          dropActive={drop.dropActive}
          isSmall={isSmall}
          onAccessPress={onAccessPress}
          onAttachPress={onAttachPress}
          sendLabel={sendLabel}
          showAccessButton={showAccessButton}
          showAttachButton={showAttachButton}
          showVoiceButton={showVoiceButton}
          submit={promptValue}
          submitPending={submitPending}
          toolbarLeading={toolbarLeading}
          toolbarTrailing={toolbarTrailing}
          voice={voice}
          voiceLabel={voiceLabel}
          voiceLevel={voiceLevel}
        />
      }
    />
  );
};
