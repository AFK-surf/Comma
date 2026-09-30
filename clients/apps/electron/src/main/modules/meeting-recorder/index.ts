import { meetingSubmissionError } from "./submission-error";
import type { MeetingTaskReceipt } from "@comma/app/api";
import type { MeetingTaskState } from "./tasks";
import {
  unavailableMeetingRecorderState,
  type CommaClientSettings,
  type AudioCaptureState,
  type AudioCaptureSource,
  type AudioCaptureStopResult,
  type MeetingPresenceMeeting,
  type MeetingPresenceState,
  type MeetingRecorderState,
  type MeetingRecorderWindowLayout,
  type MeetingRecorderWindowDrag,
} from "@comma/native-bridge";

type Action = "start" | "dismiss" | "pause" | "resume" | "stop" | "discard";
export interface MeetingRecorderProvider {
  retryTaskSync(input?: void): Promise<MeetingRecorderState>;
  layoutWindow(input: MeetingRecorderWindowLayout): Promise<void>;
  dragWindow(input: MeetingRecorderWindowDrag): Promise<void>;
  state(input?: void): Promise<MeetingRecorderState>;
  action(input: {
    action: Action;
    meetingKey: string;
    generation: number;
  }): Promise<MeetingRecorderState>;
  selectMicrophone(input: {
    deviceId: string | null;
    meetingKey: string;
    generation: number;
  }): Promise<MeetingRecorderState>;
  acknowledgeSaved(input: { receiptId: number }): Promise<void>;
  setInteractive(input: { interactive: boolean }): Promise<void>;
}

interface Dependencies {
  layoutWindow?(input: MeetingRecorderWindowLayout): void;
  dragWindow?(input: MeetingRecorderWindowDrag): void;
  enterMeeting?(meeting: MeetingPresenceMeeting): Promise<void>;
  changeMeeting?(
    meeting: MeetingPresenceMeeting,
    action: "recording" | "paused" | "dismiss" | "discard"
  ): Promise<void>;
  retryMeetings?(): void | Promise<void>;
  start(
    source: AudioCaptureSource,
    meeting: MeetingPresenceMeeting
  ): Promise<AudioCaptureState>;
  stop(options: {
    smartSummary: boolean;
    meetingKey: string;
  }): Promise<
    AudioCaptureStopResult & { summary?: Promise<MeetingTaskReceipt | void> }
  >;
  cancel(): Promise<AudioCaptureState>;
  pause(): Promise<AudioCaptureState>;
  resume(): Promise<AudioCaptureState>;
  selectMicrophone(deviceId: string | null): Promise<AudioCaptureState>;
  account(): string | undefined;
  preferences?(): Pick<
    CommaClientSettings,
    "meetingStartRecording" | "meetingHideRecorder" | "meetingSmartSummary"
  >;
  publish(state: MeetingRecorderState): void;
  setInteractive(interactive: boolean): void;
}

/** One Main owner; renderers only project this snapshot. */
export class MeetingRecorderService implements MeetingRecorderProvider {
  #snapshot: MeetingRecorderState = { ...unavailableMeetingRecorderState };
  #meetings: MeetingPresenceMeeting[] = [];
  #seen = new Set<string>();
  #answered = new Set<string>();
  #initialized = false;
  #owned = false;
  #busy = false;
  #generation = 0;
  #receipt = 0;
  #savedMeetingKey: string | undefined;
  #endingTimer: ReturnType<typeof setTimeout> | undefined;
  #closed = false;
  #account: string | undefined;
  constructor(private readonly deps: Dependencies) {
    this.#account = deps.account();
  }

  acceptTask(key: string, taskSync: MeetingTaskState) {
    if (this.#snapshot.meeting?.key === key)
      this.#set({
        taskSync: {
          status: taskSync.status,
          ...(taskSync.task ? { task: taskSync.task } : {}),
          ...(taskSync.error ? { error: taskSync.error } : {}),
        },
      });
    if (taskSync.archive && taskSync.recording) {
      this.#savedMeetingKey = key;
      this.#set({
        saved: {
          receiptId: ++this.#receipt,
          recording: taskSync.recording,
          smartSummary: true,
          summary: "queued",
          archive: taskSync.archive,
          ...(taskSync.task ? { task: taskSync.task } : {}),
        },
      });
      return;
    }
    const saved = this.#snapshot.saved;
    if (saved && this.#savedMeetingKey === key)
      this.#set({
        saved: {
          ...saved,
          summary:
            taskSync.status === "error"
              ? "error"
              : taskSync.status === "synced"
                ? "queued"
                : "pending",
          summaryError: taskSync.status === "error" ? taskSync.error : undefined,
          ...(taskSync.task ? { task: taskSync.task } : {}),
        },
      });
  }

  async retryTaskSync(_input?: void) {
    if (!this.#closed) await this.deps.retryMeetings?.();
    return this.#snapshot;
  }

  async layoutWindow(input: MeetingRecorderWindowLayout) {
    if (!this.#closed) this.deps.layoutWindow?.(input);
  }
  async dragWindow(input: MeetingRecorderWindowDrag) {
    if (!this.#closed) this.deps.dragWindow?.(input);
  }

  async state(_input?: void) {
    return this.#snapshot;
  }

  /** The first presence snapshot follows the same saved policy as later meetings. */
  initializePresence(state: MeetingPresenceState) {
    if (this.#closed || this.#initialized) return;
    this.#initialized = true;
    this.#seen = new Set(state.meetings.map((m) => m.key));
    this.#meetings = state.meetings;
    this.#offer();
  }

  acceptPresence(state: MeetingPresenceState) {
    if (!this.#initialized || this.#closed) return;
    this.#meetings = state.meetings;
    this.#seen = new Set(state.meetings.map((m) => m.key));
    this.#answered = new Set([...this.#answered].filter((key) => this.#seen.has(key)));
    this.#updateEnding();
    this.#offer();
  }

  preferencesChanged() {
    this.#set({});
    this.#offer();
  }

  acceptCapture(capture: AudioCaptureState) {
    if (this.#closed) return;
    const phase =
      this.#owned &&
      ["recording", "paused"].includes(capture.status) &&
      ["recording", "paused"].includes(this.#snapshot.phase)
        ? (capture.status as "recording" | "paused")
        : this.#snapshot.phase;
    this.#set({ capture, phase });
    if (this.#owned && capture.capped && this.#snapshot.meeting)
      void this.action({
        action: "stop",
        meetingKey: this.#snapshot.meeting.key,
        generation: this.#generation,
      });
    if (this.#owned && !this.#busy && capture.status === "idle") {
      this.#owned = false;
      this.#set({ phase: "idle", meeting: null });
    }
  }

  sessionChanged() {
    this.deps.retryMeetings?.();
    const account = this.deps.account();
    if (account === this.#account) {
      this.#offer();
      return;
    }
    this.#account = account;
    this.#generation++;
    this.#clearEnding();
    if (this.#owned) void this.deps.cancel().catch(() => undefined);
    this.#owned = false;
    this.#set({
      phase: "idle",
      meeting: null,
      saved: null,
      error: undefined,
      generation: this.#generation,
    });
    this.#offer();
  }

  async action({
    action,
    meetingKey,
    generation,
  }: {
    action: Action;
    meetingKey: string;
    generation: number;
  }) {
    const meeting = this.#snapshot.meeting;
    if (
      generation !== this.#generation ||
      this.#closed ||
      !meeting ||
      meeting.key !== meetingKey ||
      this.#busy
    )
      return this.#snapshot;
    if (action === "dismiss") {
      if (this.#owned) return this.#snapshot;
      await this.#changeMeeting(meeting, "dismiss");
      this.#answered.add(meetingKey);
      this.#set({ phase: "idle", meeting: null, error: undefined });
      this.#offer();
      return this.#snapshot;
    }
    if (
      action === "start" ? this.#owned || this.#answered.has(meetingKey) : !this.#owned
    )
      return this.#snapshot;
    if (!this.deps.account()) return this.#snapshot;
    this.#busy = true;
    this.#set({ error: undefined });
    try {
      if (action === "start") {
        this.#answered.add(meetingKey);
        this.#set({ phase: "starting", error: undefined });
        // Owner-approved Recappi-style mix. Meeting identity controls the queue,
        // while the source includes system output rather than isolating a tab.
        await this.deps
          .enterMeeting?.(meeting)
          .catch((error: unknown) => this.#taskError(error, meeting.key));
        const capture = await this.deps.start({ kind: "system" }, meeting);
        if (generation !== this.#generation || this.#closed) {
          await this.deps.cancel();
          return this.#snapshot;
        }
        if (capture.status !== "recording")
          throw new Error(capture.reason ?? "Recording could not start.");
        this.#owned = true;
        this.#set({ phase: "recording", capture });
        await this.#changeMeeting(meeting, "recording");
      } else if (action === "stop") {
        this.#clearEnding();
        this.#set({ phase: "saving" });
        const result = await this.deps.stop({
          smartSummary: this.deps.preferences?.().meetingSmartSummary ?? true,
          meetingKey: meeting.key,
        });
        this.#owned = false;
        if (generation !== this.#generation || this.#closed) return this.#snapshot;
        if (result.status !== "ready")
          throw new Error(result.reason ?? "Recording could not be saved to Drive.");
        this.#savedMeetingKey = meeting.key;
        this.#set({
          phase: "idle",
          meeting: null,
          saved: {
            receiptId: ++this.#receipt,
            recording: result.recording,
            smartSummary: this.deps.preferences?.().meetingSmartSummary ?? true,
            ...(this.#snapshot.taskSync?.task
              ? { task: this.#snapshot.taskSync.task }
              : {}),
            ...(result.summary ? { summary: "pending" as const } : {}),
          },
        });
        if (result.summary) {
          const receiptId = this.#receipt;
          const settle = (
            summary: "queued" | "error",
            receipt?: MeetingTaskReceipt | void,
            summaryError?: string
          ) => {
            const saved = this.#snapshot.saved;
            if (generation === this.#generation && saved?.receiptId === receiptId)
              this.#set({
                saved: {
                  ...saved,
                  summary,
                  summaryError,
                  ...(receipt
                    ? { task: { groupId: receipt.group_id, taskId: receipt.task_id } }
                    : {}),
                },
              });
          };
          void result.summary.then(
            (receipt) => settle("queued", receipt),
            (error: unknown) => {
              const saved = this.#snapshot.saved;
              settle(
                "error",
                undefined,
                saved?.summaryError ?? meetingSubmissionError("prepare", error)
              );
            }
          );
        }
      } else if (action === "discard") {
        await this.deps.cancel();
        await this.#changeMeeting(meeting, "discard");
        this.#owned = false;
        this.#clearEnding();
        if (generation === this.#generation)
          this.#set({ phase: "idle", meeting: null });
      } else {
        const capture = await (action === "pause"
          ? this.deps.pause()
          : this.deps.resume());
        if (generation === this.#generation) {
          this.acceptCapture(capture);
          await this.#changeMeeting(
            meeting,
            action === "pause" ? "paused" : "recording"
          );
        }
      }
    } catch (error) {
      if (generation === this.#generation && !this.#closed)
        this.#set({
          phase:
            this.#owned &&
            ["recording", "paused"].includes(this.#snapshot.capture.status)
              ? (this.#snapshot.capture.status as "recording" | "paused")
              : "error",
          error: error instanceof Error ? error.message : "Recording failed.",
        });
    } finally {
      this.#busy = false;
      if (!this.#owned) this.#offer();
      this.#updateEnding();
    }
    return this.#snapshot;
  }

  async selectMicrophone({
    deviceId,
    meetingKey,
    generation,
  }: {
    deviceId: string | null;
    meetingKey: string;
    generation: number;
  }) {
    if (
      generation !== this.#generation ||
      !this.#owned ||
      this.#busy ||
      this.#snapshot.meeting?.key !== meetingKey
    )
      return this.#snapshot;
    // MicrophoneSelection.tla already permits Stop to invalidate a pending
    // device switch. Do not serialize Stop behind permission/device opening.
    const capture = await this.deps.selectMicrophone(deviceId);
    if (
      generation === this.#generation &&
      this.#owned &&
      ["recording", "paused"].includes(this.#snapshot.phase)
    )
      this.acceptCapture(capture);
    return this.#snapshot;
  }

  setClientVisible(visible: boolean) {
    if (this.#snapshot.clientVisible !== visible) this.#set({ clientVisible: visible });
  }

  async acknowledgeSaved({ receiptId }: { receiptId: number }) {
    if (this.#snapshot.clientVisible && this.#snapshot.saved?.receiptId === receiptId)
      this.#set({ saved: null });
  }
  async setInteractive({ interactive }: { interactive: boolean }) {
    this.deps.setInteractive(interactive);
  }

  close() {
    this.#closed = true;
    this.#generation++;
    this.#clearEnding();
  }
  #set(patch: Partial<MeetingRecorderState>) {
    if (this.#closed) return;
    this.#snapshot = {
      ...this.#snapshot,
      ...patch,
      hideRecorder: this.deps.preferences?.().meetingHideRecorder ?? false,
      revision: this.#snapshot.revision + 1,
    };
    this.deps.publish(this.#snapshot);
  }
  #offer() {
    if (
      this.#closed ||
      !this.#initialized ||
      this.#owned ||
      this.#busy ||
      !this.deps.account() ||
      this.#snapshot.phase === "error"
    )
      return;
    const meeting = this.#meetings.find(
      (m) => m.status === "active" && !this.#answered.has(m.key)
    );
    const previous = this.#snapshot.meeting;
    if (
      previous &&
      previous.key !== meeting?.key &&
      this.#snapshot.phase === "detected"
    )
      void this.#changeMeeting(previous, "dismiss");
    if (meeting && previous?.key !== meeting.key) {
      this.#set({ taskSync: { status: "pending" } });
      void this.deps
        .enterMeeting?.(meeting)
        .catch((error: unknown) => this.#taskError(error, meeting.key));
    }
    const automatic =
      meeting &&
      this.deps.preferences?.().meetingStartRecording === "auto" &&
      !["recording", "paused", "finalizing"].includes(this.#snapshot.capture.status);
    this.#set({
      meeting: meeting ?? null,
      phase: meeting && !automatic ? "detected" : "idle",
    });
    if (automatic)
      void this.action({
        action: "start",
        meetingKey: meeting.key,
        generation: this.#generation,
      });
  }
  #taskError(error: unknown, key: string) {
    if (this.#closed || this.#snapshot.meeting?.key !== key) return;
    this.#set({
      taskSync: {
        ...this.#snapshot.taskSync,
        status: "error",
        error: error instanceof Error ? error.message : "Meeting sync failed.",
      },
    });
  }
  async #changeMeeting(
    meeting: MeetingPresenceMeeting,
    action: "recording" | "paused" | "dismiss" | "discard"
  ) {
    await this.deps
      .changeMeeting?.(meeting, action)
      .catch((error: unknown) => this.#taskError(error, meeting.key));
  }
  #clearEnding() {
    if (this.#endingTimer) clearTimeout(this.#endingTimer);
    this.#endingTimer = undefined;
  }
  #updateEnding() {
    if (this.#closed || !this.#owned || this.#busy) return;
    const meeting = this.#snapshot.meeting;
    if (!meeting) return;
    const current = this.#meetings.find((m) => m.key === meeting.key);
    if (current?.status === "active") {
      this.#clearEnding();
      return;
    }
    if (this.#endingTimer) return;
    // One timer per capture; no per-meeting polling or fan-out.
    this.#endingTimer = setTimeout(
      () => {
        this.#endingTimer = undefined;
        void this.action({
          action: "stop",
          meetingKey: meeting.key,
          generation: this.#generation,
        });
      },
      current ? 5_000 : 0
    );
    this.#endingTimer.unref?.();
  }
}
