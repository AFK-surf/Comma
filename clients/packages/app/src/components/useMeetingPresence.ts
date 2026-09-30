import { getNativeBridge, type MeetingPresenceState } from "@comma/native-bridge";
import { useCallback, useEffect, useState } from "react";

/**
 * Renderer view of Main's meeting detector: which meeting apps currently hold
 * the microphone. Observation only — see Main's `MeetingRecorderService` for the
 * decision to record.
 */
export function useMeetingPresence({ enabled = true }: { enabled?: boolean } = {}) {
  const bridge = getNativeBridge();
  const platformSupported = enabled && bridge.platform === "electron";
  const [state, setState] = useState<MeetingPresenceState | null>(null);

  const accept = useCallback((next: MeetingPresenceState) => {
    setState((current) =>
      current && current.revision > next.revision ? current : next
    );
  }, []);

  useEffect(() => {
    if (!platformSupported) return;
    return bridge.meetingPresence.state.subscribe(accept);
  }, [accept, bridge, platformSupported]);

  return {
    available: platformSupported && (state?.available ?? false),
    meetings: state?.meetings ?? [],
    state,
  };
}
