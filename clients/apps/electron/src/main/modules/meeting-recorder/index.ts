// Main's part of the meeting recorder: the operating system's side only. The client core decides which meeting is
// offered, when capture starts and stops, and what reaches the meeting's Task (packages/core/src/meeting). Main tells
// it what it senses (meeting presence, the capture's state, the person's meeting settings, whether the main window
// shows) and does what it says: capture audio, show the recorder window, ask about a meeting found after a restart,
// snapshot and register the saved recording with the workspace Connector, and write the meeting's outputs into Drive.
// Each command that touches the account's data runs only for the lease the core names, when it is Main's current one.
import type {
  MeetingAnswer,
  MeetingCall,
  MeetingEvent,
  MeetingFailure,
  MeetingOps,
  MeetingPreferences,
} from "@comma/core/utility-protocol";
import {
  audioCaptureSelectMicrophoneCapability,
  audioCaptureStartCapability,
  audioCaptureStopCapability,
  type AudioCaptureRecording,
  type AudioCaptureState,
  type MeetingPresenceState,
  type MeetingRecorderWindowDrag,
  type MeetingRecorderWindowLayout,
  type SynchronicityMutationResult,
} from "@comma/native-bridge";
import type { AudioCaptureService } from "../audio-capture";
import { NativeSessionAdmissionError } from "../ipc";
import type {
  LocalFileRouteRegistrationService,
  LocalFileSnapshotStore,
} from "../local-files";
import { LocalFileRouteRegistrationError } from "../local-files/registration";
import { LocalFileSnapshotError } from "../local-files/snapshot-store";
import {
  getCurrentNativeSessionAdmission,
  type MainNativeSessionAdmissionGuard,
} from "../session/native-session-admission";

/** The recorder window's geometry and pointer handling (its native leaves). */
export interface MeetingRecorderWindowProvider {
  layoutWindow(input: MeetingRecorderWindowLayout): Promise<void>;
  dragWindow(input: MeetingRecorderWindowDrag): Promise<void>;
  setInteractive(input: { interactive: boolean }): Promise<void>;
}

interface Dependencies {
  capture: Pick<
    AudioCaptureService,
    "start" | "stop" | "pause" | "resume" | "cancel" | "selectMicrophone"
  >;
  guard: Pick<MainNativeSessionAdmissionGuard, "run" | "runLease">;
  files: Pick<LocalFileSnapshotStore, "snapshot" | "markBound">;
  registrar: Pick<LocalFileRouteRegistrationService, "register">;
  /** Writes a file into the local Drive (synchronicity). */
  write(input: {
    space: string;
    path: string;
    content: string;
  }): Promise<SynchronicityMutationResult>;
  preferences(): MeetingPreferences;
  /** Shows the recorder window before capture starts (unless the person hides it). */
  prepareWindow?(): Promise<void>;
  /** Asks whether a meeting found after a restart is the one before it. */
  resolveRecovery?(name: string): Promise<"resume" | "new">;
  window?: {
    layout(input: MeetingRecorderWindowLayout): void;
    drag(input: MeetingRecorderWindowDrag): void;
    setInteractive(interactive: boolean): void;
  };
}

const storageCodes = new Set(["ENOSPC", "EACCES", "EPERM", "EIO", "ENOENT"]);

/** Why a command failed, as the core may know it: no host path, response body or credential. */
export function meetingFailure(error: unknown): MeetingFailure {
  if (error instanceof LocalFileRouteRegistrationError)
    return {
      kind: "registration",
      retryable: error.retryable,
      ...(error.remediation ? { remediation: error.remediation } : {}),
    };
  if (error instanceof LocalFileSnapshotError)
    return { kind: "snapshot", errorClass: error.errorClass };
  if (error instanceof NativeSessionAdmissionError) return { kind: "session" };
  if (
    error &&
    typeof error === "object" &&
    "code" in error &&
    storageCodes.has(String(error.code))
  )
    return { kind: "storage", code: String(error.code) };
  return {
    kind: "failed",
    ...(error instanceof Error && error.message ? { reason: error.message } : {}),
  };
}

export class MeetingRecorderMain implements MeetingRecorderWindowProvider {
  readonly #deps: Dependencies;
  #send: (event: MeetingEvent) => void = () => undefined;
  /** Presence once detection started (the core's first offer waits for it). */
  #presence: MeetingPresenceState | undefined;
  #capture: AudioCaptureState | undefined;
  /** The meeting the running capture was started for: the core takes it up again after a restart. */
  #captureMeeting: string | undefined;
  #clientVisible = false;
  #starting = false;

  constructor(deps: Dependencies) {
    this.#deps = deps;
  }

  /** Where events go (the core's utility process); what Main knows now is told at once. */
  connect(send: (event: MeetingEvent) => void): void {
    this.#send = send;
  }

  /** What the core is told when it (re)starts. */
  events(): MeetingEvent[] {
    return [
      { kind: "preferences", preferences: this.#deps.preferences() },
      { kind: "clientVisible", visible: this.#clientVisible },
      ...(this.#capture
        ? [
            {
              kind: "capture" as const,
              state: this.#capture,
              ...(this.#captureMeeting ? { meetingKey: this.#captureMeeting } : {}),
            },
          ]
        : []),
      ...(this.#presence ? [{ kind: "presence" as const, state: this.#presence }] : []),
    ];
  }

  /** Meeting detection started (`started`) or saw a change: told only once it started. */
  presenceChanged(state: MeetingPresenceState, started = false): void {
    if (!started && !this.#presence) return;
    this.#presence = state;
    this.#send({ kind: "presence", state });
  }

  captureChanged(state: AudioCaptureState): void {
    this.#capture = state;
    // A capture that ended is no meeting's (one opening is the meeting's that `start` named).
    if ((state.status === "idle" || state.status === "unavailable") && !this.#starting)
      this.#captureMeeting = undefined;
    this.#send({
      kind: "capture",
      state,
      ...(this.#captureMeeting ? { meetingKey: this.#captureMeeting } : {}),
    });
  }

  preferencesChanged(): void {
    this.#send({ kind: "preferences", preferences: this.#deps.preferences() });
  }

  setClientVisible(visible: boolean): void {
    if (this.#clientVisible === visible) return;
    this.#clientVisible = visible;
    this.#send({ kind: "clientVisible", visible });
  }

  async layoutWindow(input: MeetingRecorderWindowLayout) {
    this.#deps.window?.layout(input);
  }

  async dragWindow(input: MeetingRecorderWindowDrag) {
    this.#deps.window?.drag(input);
  }

  async setInteractive({ interactive }: { interactive: boolean }) {
    this.#deps.window?.setInteractive(interactive);
  }

  /** A command from the core: its answer, or why it failed. */
  async command(call: MeetingCall): Promise<MeetingAnswer> {
    try {
      return { ok: await this.#run(call) };
    } catch (error) {
      return { failure: meetingFailure(error) };
    }
  }

  async #run(call: MeetingCall): Promise<MeetingOps[MeetingCall["op"]]["output"]> {
    const deps = this.#deps;
    switch (call.op) {
      case "start": {
        const { lease, meeting, archiveAtMs } = call.input;
        if (!deps.preferences().meetingHideRecorder) await deps.prepareWindow?.();
        const input = {
          session: lease,
          source: { kind: "system" as const },
          microphone: true,
        };
        // The capture's own reports name the meeting from the start.
        this.#captureMeeting = meeting.key;
        this.#starting = true;
        try {
          const state = await deps.guard.run({
            contract: audioCaptureStartCapability.contract,
            input,
            // The saved file is named by the meeting's platform (`Zoom 2026-10-09 14.30-15.15.m4a`). Another
            // browser's name is no platform, as in the Task's title: its file is a `Meeting`.
            handler: () =>
              deps.capture.start(input, {
                platform:
                  meeting.kind === "browser" && !meeting.browserTabId
                    ? "Meeting"
                    : meeting.name,
                archiveAtMs,
              }),
          });
          if (state.status !== "recording") this.#captureMeeting = undefined;
          return state;
        } catch (error) {
          this.#captureMeeting = undefined;
          throw error;
        } finally {
          this.#starting = false;
        }
      }
      case "stop": {
        const input = { session: call.input.lease };
        let savedPath!: (path: string) => void;
        const saved = new Promise<string>((resolve) => (savedPath = resolve));
        const result = await deps.guard.run({
          contract: audioCaptureStopCapability.contract,
          input,
          // The meeting's audio goes to its Task (the core sends it), not to the transcription of a plain recording.
          handler: () =>
            deps.capture.stop(
              input,
              async (_recording: AudioCaptureRecording, _target, path) =>
                savedPath(path)
            ),
        });
        this.#captureMeeting = undefined;
        if (result.status !== "ready")
          return {
            status: "unavailable",
            ...(result.reason ? { reason: result.reason } : {}),
          };
        return {
          status: "ready",
          recording: result.recording,
          sourcePath: await saved,
        };
      }
      case "pause":
        return deps.capture.pause();
      case "resume":
        return deps.capture.resume();
      case "cancel":
        this.#captureMeeting = undefined;
        return deps.capture.cancel();
      case "selectMicrophone": {
        const input = { session: call.input.lease, deviceId: call.input.deviceId };
        return deps.guard.run({
          contract: audioCaptureSelectMicrophoneCapability.contract,
          input,
          handler: () => deps.capture.selectMicrophone(input),
        });
      }
      case "recover":
        if (!deps.resolveRecovery)
          throw new Error("Open Comma to resolve the previous meeting Task.");
        return deps.resolveRecovery(call.input.name);
      case "snapshot": {
        const { lease, sourcePath } = call.input;
        return deps.guard.runLease(lease, () =>
          deps.files.snapshot(
            sourcePath,
            getCurrentNativeSessionAdmission().principalUserId
          )
        );
      }
      case "register": {
        const { lease, workspaceId, file } = call.input;
        return deps.guard.runLease(lease, async (assertCurrent) => {
          await deps.registrar.register(workspaceId, file, assertCurrent);
          return null;
        });
      }
      case "markBound":
        await deps.files.markBound(call.input.localFileRef);
        return null;
      case "write": {
        const { lease, space, path, content } = call.input;
        return deps.guard.runLease(lease, async (assertCurrent) => {
          const result = await deps.write({ space, path, content });
          if (result.status !== "done")
            throw new Error("Drive did not accept the meeting output.");
          assertCurrent();
          return null;
        });
      }
      case "legacy":
        // The utility process reads Main's old journal itself.
        return null;
    }
  }
}
