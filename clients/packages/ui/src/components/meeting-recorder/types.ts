/**
 * Lifecycle of one meeting recording as the user sees it. The card is fully
 * controlled: the app maps native capture + presence state onto a phase and
 * the card only draws it.
 */
export type MeetingRecorderPhase =
  /** A meeting app took the microphone; offer to record. */
  | "detected"
  /** Start was pressed; the system tap and microphone are opening. */
  | "starting"
  | "recording"
  | "paused"
  /** Stop was pressed (or the call ended); tracks are being mixed and stored. */
  | "saving"
  | "saved"
  | "error";

export type MeetingRecorderMicrophone = "on" | "off" | "unavailable";

export type MeetingRecorderPermission = "granted" | "unknown" | "suspected_denied";

export interface MeetingRecorderProps {
  menuPlacement?: "bottom start" | "bottom end";
  phase: MeetingRecorderPhase;
  /** Collapse an unattended recording; static showcases can keep all controls visible. */
  collapseWhenIdle?: boolean;
  /** Name of the meeting app or browser holding the call, e.g. "Zoom". */
  appName?: string;
  /** Actual meeting application's OS icon; unknown browser calls have no product logo. */
  appIconUrl?: string;
  microphoneDevices?: readonly { id: string; label: string; isDefault?: boolean }[];
  microphoneDeviceId?: string;
  microphonePending?: boolean;
  microphoneLoading?: boolean;
  microphoneError?: string;
  onMenuOpenChange?: (open: boolean) => void;
  onMicrophoneMenuOpen?: () => void;
  onMicrophoneChange?: (deviceId: string | null) => void;
  onDiscard?: () => void;
  /** Recorded time in milliseconds; frozen while paused, final once saved. */
  durationMs?: number;
  /** Measured 0..1 capture level. Omitted where no capture backs the card. */
  level?: number;
  microphone?: MeetingRecorderMicrophone;
  /** System-audio permission heuristic from the capture service. */
  permission?: MeetingRecorderPermission;
  /** The call has ended and the recording is about to stop on its own. */
  callEnded?: boolean;
  /** Stored file name, shown in the `saved` phase. */
  fileName?: string;
  /** Human-readable failure, shown in the `error` phase. */
  errorMessage?: string;
  /** File action in progress; both saved-file actions are disabled until it settles. */
  fileActionPending?: "reveal" | "open";
  /** A saved-file action failed; the recording remains saved and can be retried. */
  fileActionError?: string;
  onStart?: () => void;
  /** "Not now" on the detected card. */
  onDismiss?: () => void;
  onPause?: () => void;
  onResume?: () => void;
  onStop?: () => void;
  onOpenPermissionSettings?: () => void;
  /** Reveal the saved recording in its Drive folder. */
  onRevealInDrive?: () => void;
  /** Open the saved recording with the system's default application. */
  onOpenFile?: () => void;
  /** Close the saved / error card. */
  onClose?: () => void;
  className?: string;
  testId?: string;
}
