import { useApplicationMenu } from "./application-menu/useApplicationMenu";
import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { DraggableRecorder, MeetingRecordingBlock, toast } from "@comma/ui";
import { useEffect, useRef } from "react";
import { useMeetingRecorder } from "./useMeetingRecorder";
import { useRecordingFileActions } from "./useRecordingFileActions";

/** Client projection: live block at bottom left; completion uses the regular Toaster. */
export function MeetingRecorderHost({
  containment,
}: { containment?: HTMLElement | null | undefined } = {}) {
  const { state, action, error } = useMeetingRecorder();
  const { showSaved } = useRecordingFileActions();
  const messages = useCommaMessages();
  const visible = state.clientVisible;
  const shownReceipt = useRef<string | undefined>(undefined);
  useEffect(() => {
    const receipt = state.saved;
    if (!visible || !receipt) return;
    const key = `${receipt.receiptId}:${receipt.summary ?? "saved"}:${receipt.summaryError ?? ""}`;
    if (key === shownReceipt.current) return;
    shownReceipt.current = key;
    showSaved(
      receipt.recording,
      `meeting-recording-${receipt.receiptId}`,
      "meeting-recording-saved",
      {
        summary: receipt.summary,
        summaryError: receipt.summaryError,
        task: receipt.task,
        smartSummary: receipt.smartSummary,
        archive: receipt.archive,
      }
    );
    if (
      receipt.summary === "pending" ||
      receipt.summary === "error" ||
      receipt.archive === "error"
    )
      return;
    void getNativeBridge().meetingRecorder.acknowledgeSaved({
      receiptId: receipt.receiptId,
    });
  }, [showSaved, state.saved, visible]);
  const issue = error ?? state.error ?? state.taskSync?.error;
  useEffect(() => {
    if (visible && issue) toast.error(issue, { id: "meeting-recorder-action" });
  }, [issue, visible]);
  useApplicationMenu(
    state.phase === "recording" || state.phase === "paused"
      ? [
          {
            id: "record-pause",
            enabled: state.phase === "recording",
            run: () => action("pause"),
          },
          {
            id: "record-resume",
            enabled: state.phase === "paused",
            run: () => action("resume"),
          },
          { id: "record-stop", enabled: true, run: () => action("stop") },
        ]
      : []
  );
  if (state.phase !== "recording" && state.phase !== "paused") return null;
  return (
    <DraggableRecorder
      label={messages.ui_meeting_recorder_label()}
      containment={containment}
    >
      <MeetingRecordingBlock
        paused={state.phase === "paused"}
        level={state.capture.level}
        onPause={() => action("pause")}
        onResume={() => action("resume")}
        onStop={() => action("stop")}
      />
    </DraggableRecorder>
  );
}
