import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { ChevronDownIcon, PlusIcon, ShieldCheckIcon } from "../../icons";
import { Tooltip } from "../../tooltip";
import { cx } from "../../utils";
import {
  aiInputAccessButton,
  aiInputControlSmallSize,
  aiInputIconButton,
  aiInputSmallToolbar,
  aiInputToolbar,
} from "../styles";
import type { ForwardedAiInputProps } from "../types";
import { AiInputVoiceRecording } from "../voice/AiInputVoiceRecording";
import {
  ToolbarSendControls,
  type ToolbarSendControlsProps,
} from "./ToolbarSendControls";
import type { AttachTooltip } from "./useAttachTooltip";

export interface AiInputToolbarProps
  extends
    ToolbarSendControlsProps,
    ForwardedAiInputProps<
      | "accessLabel"
      | "attachLabel"
      | "onAccessPress"
      | "onAttachPress"
      | "toolbarLeading"
      | "voiceLevel"
    > {
  attachTooltip: AttachTooltip;
  disabled: boolean;
  showAccessButton: boolean;
  showAttachButton: boolean;
}

/**
 * The row under the prompt: the leading controls, then the send controls or,
 * while dictating, the recording strip in their place.
 */
export const AiInputToolbar = (props: AiInputToolbarProps) => {
  const {
    accessLabel,
    attachLabel,
    attachTooltip,
    disabled,
    dropActive,
    isSmall,
    onAccessPress,
    onAttachPress,
    showAccessButton,
    showAttachButton,
    toolbarLeading,
    voice,
    voiceLevel,
  } = props;
  const messages = useCommaMessages();
  const { attachTooltipSuppressed } = attachTooltip;
  const { isVoiceRecording } = voice;

  return (
    <div
      className={cx(
        isVoiceRecording ? "flex h-9 w-full items-center gap-md" : aiInputToolbar,
        isSmall && aiInputSmallToolbar
      )}
      data-slot="ai-input-toolbar"
    >
      <div
        className={cx(
          "flex min-w-0 items-center gap-xxs",
          isVoiceRecording ? "shrink-0" : "flex-1"
        )}
        data-slot="ai-input-toolbar-leading"
      >
        {toolbarLeading}
        {showAttachButton ? (
          <Tooltip
            content={messages.ui_ai_add_files_and_more()}
            isDisabled={attachTooltipSuppressed}
            placement="top"
            shortcut="@"
          >
            <AriaButton
              aria-label={attachLabel ?? messages.ui_ai_add_attachment()}
              data-attach-tooltip-suppressed={
                attachTooltipSuppressed ? "true" : "false"
              }
              className={cx(
                aiInputIconButton,
                aiInputControlSmallSize,
                isSmall && "pointer-events-auto",
                "bg-quaternary hover:bg-fg-senary"
              )}
              isDisabled={disabled || dropActive || !onAttachPress}
              onBlur={attachTooltip.handleAttachButtonBlur}
              onFocus={attachTooltip.handleAttachButtonFocus}
              ref={attachTooltip.attachButtonRef}
              {...(onAttachPress
                ? { onPress: attachTooltip.handleAttachButtonPress }
                : {})}
            >
              <PlusIcon className="size-4" />
            </AriaButton>
          </Tooltip>
        ) : null}
        {showAccessButton && !isVoiceRecording ? (
          <AriaButton
            className={aiInputAccessButton}
            isDisabled={disabled || dropActive || !onAccessPress}
            {...(onAccessPress ? { onPress: onAccessPress } : {})}
          >
            <ShieldCheckIcon className="size-5 text-ai-input-panel-icon-warning" />
            <span className="shrink-0 whitespace-nowrap px-xxs">
              {accessLabel ?? messages.ui_ai_full_access()}
            </span>
            <ChevronDownIcon className="size-5" />
          </AriaButton>
        ) : null}
      </div>
      {isVoiceRecording ? (
        <AiInputVoiceRecording
          cancelLabel={messages.ui_ai_cancel_voice_recording()}
          {...(isSmall ? { className: "pointer-events-auto" } : {})}
          confirmLabel={messages.ui_ai_confirm_voice_recording()}
          durationSeconds={voice.voiceDuration}
          {...(voiceLevel === undefined ? {} : { level: voiceLevel })}
          recordingLabel={messages.ui_ai_voice_recording()}
          onCancel={voice.cancelVoiceRecording}
          onConfirm={voice.confirmVoiceRecording}
        />
      ) : (
        <div
          className="flex shrink-0 items-center gap-md"
          data-slot="ai-input-toolbar-trailing"
        >
          <ToolbarSendControls {...props} />
        </div>
      )}
    </div>
  );
};
