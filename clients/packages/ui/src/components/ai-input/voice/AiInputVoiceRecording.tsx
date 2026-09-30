/* oxlint-disable jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/prefer-tag-over-role -- Recording strip is a focusable control group that owns its Enter/Escape shortcuts, not a fieldset form grouping. */
import { useEffect, useRef, type KeyboardEvent } from "react";
import { Button as AriaButton } from "react-aria-components";
import { CheckIcon, XIcon } from "../../icons";
import { cx } from "../../utils";
import { AiInputVoiceWaveform } from "./AiInputVoiceWaveform";
import {
  aiInputVoiceRecording,
  aiInputVoiceRecordingActions,
  aiInputVoiceRecordingControl,
} from "../styles";
import {
  AI_INPUT_VOICE_DURATION_WIDTH_PX,
  formatVoiceDuration,
} from "./voiceRecording";

export const AiInputVoiceRecording = ({
  className,
  durationSeconds,
  level,
  recordingLabel,
  cancelLabel,
  confirmLabel,
  onCancel,
  onConfirm,
}: {
  className?: string;
  durationSeconds: number;
  /** Measured 0..1 capture level; omitted where no capture is wired up. */
  level?: number;
  recordingLabel: string;
  cancelLabel: string;
  confirmLabel: string;
  onCancel: () => void;
  onConfirm: () => void;
}) => {
  const rootRef = useRef<HTMLDivElement>(null);

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onCancel();
      return;
    }

    if (
      event.key === "Enter" &&
      !event.shiftKey &&
      event.target === event.currentTarget
    ) {
      event.preventDefault();
      event.stopPropagation();
      onConfirm();
    }
  };

  useEffect(() => {
    rootRef.current?.focus();
  }, []);

  return (
    <div
      aria-keyshortcuts="Enter Escape"
      aria-label={recordingLabel}
      className={cx(
        aiInputVoiceRecording,
        "outline-none focus-visible:shadow-focus-gray",
        className
      )}
      data-slot="ai-input-voice-recording"
      onKeyDown={handleKeyDown}
      ref={rootRef}
      role="group"
      tabIndex={-1}
    >
      <AiInputVoiceWaveform
        label={recordingLabel}
        {...(level === undefined ? {} : { level })}
      />
      <span
        className="shrink-0 text-right text-sm font-medium tabular-nums leading-5 text-ai-input-panel-icon-primary"
        data-slot="ai-input-voice-duration"
        style={{ width: AI_INPUT_VOICE_DURATION_WIDTH_PX }}
      >
        {formatVoiceDuration(durationSeconds)}
      </span>
      <div
        className={aiInputVoiceRecordingActions}
        data-slot="ai-input-voice-recording-actions"
      >
        <AriaButton
          aria-label={cancelLabel}
          className={aiInputVoiceRecordingControl}
          onPress={onCancel}
        >
          <XIcon className="size-6" />
        </AriaButton>
        <AriaButton
          aria-label={confirmLabel}
          className={aiInputVoiceRecordingControl}
          onPress={onConfirm}
        >
          <CheckIcon className="size-6" />
        </AriaButton>
      </div>
    </div>
  );
};
