import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "../Button";
import { meetingWaveformLevel } from "./waveformLevel";
import { PauseIcon, PlayIcon, StopIcon } from "../icons";
import { CommaMark } from "../login/BrandMarks";
import { AiInputVoiceWaveform } from "../ai-input/voice/AiInputVoiceWaveform";

/** Figma 1457:17693, Frame 1686557479. One shared capture, no local recorder. */
export function MeetingRecordingBlock({
  paused,
  level,
  onPause,
  onResume,
  onStop,
}: {
  paused: boolean;
  level: number;
  onPause(): void;
  onResume(): void;
  onStop(): void;
}) {
  const m = useCommaMessages();
  return (
    <div
      className="comma-recording-block"
      data-slot="meeting-recording-block"
      data-paused={paused || undefined}
    >
      <div className="flex items-center gap-md" data-recorder-drag-handle>
        <CommaMark className="size-5 text-primary" viewBox="3.75 4.44 40.56 40.56" />
        <span
          className={paused ? "text-mini text-disabled" : "text-mini comma-shiny-text"}
        >
          {paused
            ? m.ui_meeting_recorder_paused()
            : m.ui_meeting_recorder_block_recording()}
        </span>
      </div>
      <div className="flex h-6 w-full" aria-hidden={paused || undefined}>
        <AiInputVoiceWaveform
          label={m.ui_meeting_recorder_block_recording()}
          level={paused ? 0 : meetingWaveformLevel(level)}
        />
      </div>
      <div className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)] gap-xs">
        <Button
          size="xs"
          hierarchy="secondary-gray"
          className="h-[26px] min-w-0 px-xs"
          iconLeading={paused ? <PlayIcon /> : <PauseIcon />}
          onPress={paused ? onResume : onPause}
        >
          {paused
            ? m.ui_meeting_recorder_block_resume()
            : m.ui_meeting_recorder_block_pause()}
        </Button>
        <Button
          size="xs"
          hierarchy="destructive"
          className="h-[26px] min-w-0 px-xs"
          iconLeading={<StopIcon />}
          onPress={onStop}
        >
          {m.ui_meeting_recorder_block_stop()}
        </Button>
      </div>
    </div>
  );
}
