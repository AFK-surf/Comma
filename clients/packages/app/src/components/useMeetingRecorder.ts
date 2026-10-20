import { useCall, useTopic, type MeetingRecorderValue } from "@comma/core-client";
import { useCallback, useState } from "react";

const unavailable: MeetingRecorderValue = {
  clientVisible: false,
  phase: "idle",
  revision: 1,
  generation: 0,
  meeting: null,
  capture: {
    available: false,
    capped: false,
    channels: 0,
    durationMs: 0,
    level: 0,
    microphone: "off",
    permission: "unknown",
    revision: 1,
    sampleRate: 0,
    status: "unavailable",
  },
  saved: null,
};

/** The client core's meeting recorder: every window shows the same one, and acts on it with its calls. */
export function useMeetingRecorder() {
  const state = useTopic({ topic: "meetingRecorder" }).value ?? unavailable;
  const call = useCall();
  const [error, setError] = useState<string>();
  const action = useCallback(
    (intent: "start" | "dismiss" | "pause" | "resume" | "stop" | "discard") => {
      if (!state.meeting) return;
      setError(undefined);
      void call("meetingRecorder.action", {
        action: intent,
        meetingKey: state.meeting.key,
        generation: state.generation,
      }).catch((failure: unknown) => {
        setError(
          failure instanceof Error ? failure.message : "Recording action failed."
        );
      });
    },
    [call, state.meeting, state.generation]
  );
  return { state, action, error };
}
