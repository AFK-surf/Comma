import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import type { MeetingTaskReference } from "@comma/core/contract";
import { getNativeBridge, type AudioCaptureRecording } from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";
import { useRouter } from "@tanstack/react-router";
import { useCallback, useContext, useRef, useState } from "react";
import { CommaAuthContext } from "./auth-context";
import { openTaskTarget } from "./tasks/openTaskTarget";

let revealSequence = 0;

/** The card and both recording completion paths act on Main's saved target. */
export function useRecordingFileActions() {
  const messages = useCommaMessages();
  // Composers also render in isolated previews without a route or session.
  const router = useRouter({ warn: false });
  const productLease = useContext(CommaAuthContext)?.productLease;
  const [pending, setPending] = useState<"reveal" | "open">();
  const [error, setError] = useState<string>();
  const busy = useRef(false);
  const call = useCall();

  const reveal = useCallback(
    async (recording: AudioCaptureRecording) => {
      if (busy.current) return;
      busy.current = true;
      setPending("reveal");
      setError(undefined);
      try {
        if (!router) throw new Error("Drive navigation is unavailable.");
        await router.navigate({
          to: "/drive",
          search: {
            path: recording.driveFile.path,
            reveal: `recording-${++revealSequence}`,
            space: recording.driveFile.space,
          },
        });
      } catch {
        const message = messages.recording_reveal_failed();
        setError(message);
        toast.error(message, { id: "recording-reveal-failed" });
      } finally {
        busy.current = false;
        setPending(undefined);
      }
    },
    [messages, router]
  );

  const open = useCallback(
    async (recording: AudioCaptureRecording) => {
      if (busy.current) return;
      busy.current = true;
      setPending("open");
      setError(undefined);
      let detail: string | undefined;
      try {
        if (!productLease) throw new Error("Recording session is unavailable.");
        const result = await getNativeBridge().audioCapture.openSaved({
          driveFile: recording.driveFile,
          session: productLease,
        });
        if (result.status !== "opened") {
          detail = result.reason;
          throw new Error("Recording could not be opened.");
        }
      } catch {
        const message = [messages.recording_open_failed(), detail]
          .filter(Boolean)
          .join(" ");
        setError(message);
        toast.error(message, { id: "recording-open-failed" });
      } finally {
        busy.current = false;
        setPending(undefined);
      }
    },
    [messages, productLease]
  );

  const showSaved = useCallback(
    (
      recording: AudioCaptureRecording,
      id: string,
      testId: string,
      meeting?: {
        summary?: "pending" | "queued" | "error" | undefined;
        summaryError?: string | undefined;
        smartSummary?: boolean | undefined;
        archive?: "done" | "missing" | "pending" | "error" | undefined;
        task?: MeetingTaskReference | undefined;
      }
    ) => {
      setError(undefined);
      // Only a Task the server saved can be opened.
      const task = meeting?.summary !== undefined ? meeting.task : undefined;
      const archiveFailed =
        meeting?.archive !== undefined && meeting.archive !== "done";
      const show =
        meeting?.summary === "error" || archiveFailed ? toast.error : toast.success;
      const title =
        meeting?.archive === "error"
          ? messages.meeting_archive_failed()
          : meeting?.archive === "missing"
            ? messages.meeting_archive_missing()
            : meeting?.archive === "pending"
              ? messages.meeting_archive_pending()
              : meeting?.archive === "done"
                ? messages.meeting_archive_done()
                : meeting?.summary === "pending" && meeting.smartSummary !== false
                  ? messages.recording_summary_preparing()
                  : meeting?.summary === "error"
                    ? messages.recording_summary_failed()
                    : messages.chat_voice_capture_saved({ name: recording.file.name });
      const message =
        meeting?.summary === "error" && meeting.summaryError
          ? `${title} ${meeting.summaryError}`
          : title;
      show(message, {
        actions: meeting
          ? [
              ...(task
                ? [
                    {
                      hierarchy: "secondary-gray" as const,
                      label:
                        meeting.smartSummary === false
                          ? messages.recording_view_meeting()
                          : messages.recording_check_summary(),
                      onPress: () =>
                        void router?.navigate(
                          openTaskTarget({
                            conversationId: task.taskId,
                            groupId: task.groupId,
                            workspaceId: task.workspaceId,
                          })
                        ),
                    },
                  ]
                : []),
              ...(meeting.summary === "error" || archiveFailed
                ? [
                    {
                      hierarchy: "tertiary-gray" as const,
                      label: messages.common_retry(),
                      onPress: () => {
                        void call("meetingRecorder.retryTaskSync", {}).catch(() =>
                          toast.error(messages.recording_summary_failed())
                        );
                      },
                    },
                  ]
                : []),
              {
                hierarchy: task ? "tertiary-gray" : "secondary-gray",
                label: messages.ui_meeting_recorder_show_in_drive(),
                onPress: () => void reveal(recording),
              },
            ]
          : [
              {
                hierarchy: "secondary-gray",
                label: messages.ui_meeting_recorder_show_in_drive(),
                onPress: () => void reveal(recording),
              },
              {
                hierarchy: "tertiary-gray",
                label: messages.ui_meeting_recorder_open_file(),
                onPress: () => void open(recording),
              },
            ],
        id,
        testId,
      });
    },
    [call, messages, open, reveal, router]
  );

  return { error, open, pending, reveal, showSaved };
}
