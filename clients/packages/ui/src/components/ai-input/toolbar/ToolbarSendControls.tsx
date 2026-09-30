import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { ArrowUpIcon, MicrophoneFilledIcon } from "../../icons";
import { cx } from "../../utils";
import {
  aiInputControlSmallSize,
  aiInputIconButton,
  aiInputSendButton,
} from "../styles";
import type { PromptValue } from "../prompt/usePromptValue";
import type { ForwardedAiInputProps } from "../types";
import type { VoiceRecording } from "../voice/useVoiceRecording";
import { SendInputTooltip, VoiceInputTooltip } from "./toolbarTooltips";

export interface ToolbarSendControlsProps extends ForwardedAiInputProps<
  "sendLabel" | "toolbarTrailing" | "voiceLabel"
> {
  dropActive: boolean;
  isSmall: boolean;
  showVoiceButton: boolean;
  /** Whether there is something to send, whether it can go now, and sending it. */
  submit: Pick<PromptValue, "canSubmit" | "filled" | "handleSubmit">;
  submitPending: boolean;
  voice: VoiceRecording;
}

/**
 * The trailing controls: the host's slot, the voice button once there is
 * something to send, and the send button, which starts dictation instead
 * while the prompt is empty.
 */
export const ToolbarSendControls = ({
  dropActive,
  isSmall,
  sendLabel,
  showVoiceButton,
  submit: { canSubmit, filled, handleSubmit },
  submitPending,
  toolbarTrailing,
  voice,
  voiceLabel,
}: ToolbarSendControlsProps) => {
  const messages = useCommaMessages();
  const { canStartVoiceRecording, startVoiceRecording, voiceTriggerRef } = voice;
  const resolvedVoiceLabel = voiceLabel ?? messages.ui_ai_voice_input();
  const resolvedSendLabel = sendLabel ?? messages.ui_ai_send_message();
  const showSendAsVoice = showVoiceButton && !filled && !submitPending;
  const voiceInputTooltipPrefix = messages.ui_ai_click_or_hold();
  const voiceInputTooltipSuffix = messages.ui_ai_to_dictate();
  const sendButton = (
    <AriaButton
      aria-label={
        submitPending
          ? messages.ui_ai_sending_message()
          : showSendAsVoice
            ? resolvedVoiceLabel
            : resolvedSendLabel
      }
      className={cx(
        aiInputSendButton,
        aiInputControlSmallSize,
        isSmall && "pointer-events-auto",
        showSendAsVoice || (canSubmit && !dropActive) || submitPending
          ? "bg-button-primary-bg text-ai-input-panel-icon-fg hover:bg-button-primary-bg-hover"
          : "bg-ai-input-panel-bg-disabled text-ai-input-panel-icon-disabled"
      )}
      data-submit-state={submitPending ? "pending" : "idle"}
      isDisabled={
        dropActive || (showSendAsVoice ? !canStartVoiceRecording : !canSubmit)
      }
      isPending={submitPending}
      onPress={showSendAsVoice ? startVoiceRecording : handleSubmit}
      ref={showSendAsVoice ? voiceTriggerRef : undefined}
    >
      {submitPending ? (
        <span
          aria-hidden
          className="size-3.5 animate-spin rounded-full border-2 border-current border-r-transparent"
          data-testid="ai-input-submit-spinner"
        />
      ) : showSendAsVoice ? (
        <MicrophoneFilledIcon className="size-4" />
      ) : (
        <ArrowUpIcon className="size-4" />
      )}
    </AriaButton>
  );

  return (
    <>
      {toolbarTrailing}
      {showVoiceButton && filled ? (
        <VoiceInputTooltip
          prefix={voiceInputTooltipPrefix}
          suffix={voiceInputTooltipSuffix}
        >
          <AriaButton
            aria-label={resolvedVoiceLabel}
            className={cx(
              aiInputIconButton,
              aiInputControlSmallSize,
              isSmall && "pointer-events-auto",
              "bg-transparent hover:bg-quaternary"
            )}
            isDisabled={dropActive || !canStartVoiceRecording}
            onPress={startVoiceRecording}
            ref={voiceTriggerRef}
          >
            <MicrophoneFilledIcon className="size-4" />
          </AriaButton>
        </VoiceInputTooltip>
      ) : null}
      {showSendAsVoice ? (
        <VoiceInputTooltip
          prefix={voiceInputTooltipPrefix}
          suffix={voiceInputTooltipSuffix}
        >
          {sendButton}
        </VoiceInputTooltip>
      ) : (
        <SendInputTooltip
          newLineLabel={messages.ui_ai_new_line()}
          sendLabel={messages.ui_ai_send()}
        >
          {sendButton}
        </SendInputTooltip>
      )}
    </>
  );
};
