// Electron's meeting recorder: which meeting is offered, when capture starts and stops, and the meeting's Task. Main
// senses meetings (presence), captures audio, shows the recorder window and keeps files; it tells the core what it
// sees (`MeetingPorts.listen`) and does what the core says (`MeetingPorts.command`). Every window shows the
// `meetingRecorder` topic and acts with its calls.
//
// One fiber owns the recorder's state: it takes its inputs from one queue in turn (what Main saw, the session's
// changes, the meeting Task's sync, the windows' calls, the ending grace, and the ends of the steps it started) and is
// the only writer of what the topic shows. A step that waits on Main or the Task lane (start, stop, pause, a
// microphone change) runs as a fiber of its own and reports its end as an input; the recorder is `busy` meanwhile and
// refuses other controls, but keeps taking what Main sees.
//
// Bounds: one meeting offered or recorded at a time, one step at a time, one timer per capture (the meeting's 5 s ending
// grace), no polling; the Task lane's bounds are tasks.ts's.
import { CoreError, type Scoped, type Value } from "@comma/core-kernel";
import type { CommaLocale } from "@comma/i18n";
import {
  Cause,
  Deferred,
  Duration,
  Effect,
  Exit,
  type Fiber,
  Queue,
  Stream,
} from "effect";
import type { MeetingRecorderAction, MeetingRecorderValue } from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import type {
  MeetingCaptureState,
  MeetingEvent,
  MeetingOps,
  MeetingPorts,
  MeetingPreferences,
  MeetingPresenceMeeting,
} from "../host.ts";
import { meetingSubmissionError } from "./errors.ts";
import { meetingCommand } from "./ports.ts";
import {
  MeetingTasks,
  type MeetingTaskReceipt,
  type MeetingTaskState,
} from "./tasks.ts";

export const unavailableMeetingCapture: MeetingCaptureState = {
  available: false,
  capped: false,
  channels: 0,
  durationMs: 0,
  level: 0,
  microphone: "off",
  permission: "unknown",
  reason: "Audio capture is unavailable in this runtime.",
  revision: 1,
  sampleRate: 0,
  status: "unavailable",
};

export const unavailableMeetingRecorder: MeetingRecorderValue = {
  clientVisible: false,
  phase: "idle",
  revision: 1,
  generation: 0,
  meeting: null,
  capture: unavailableMeetingCapture,
  saved: null,
};

const defaultPreferences: MeetingPreferences = {
  meetingStartRecording: "reminder",
  meetingHideRecorder: false,
  meetingSmartSummary: true,
};

const ACTIONS = new Set<MeetingRecorderAction>([
  "start",
  "dismiss",
  "pause",
  "resume",
  "stop",
  "discard",
]);
const ENDING_GRACE_MS = 5_000;

type Reply = Deferred.Deferred<MeetingRecorderValue, CoreError>;
type StopResult = MeetingOps["stop"]["output"];

/** What the recorder's fiber takes, in turn. */
type Input =
  | { kind: "event"; event: MeetingEvent }
  | { kind: "session" }
  | { kind: "task"; key: string; state: MeetingTaskState }
  | { kind: "taskError"; key: string; error: unknown }
  | {
      kind: "action";
      action: MeetingRecorderAction;
      meetingKey: string;
      generation: number;
      reply?: Reply;
    }
  | {
      kind: "microphone";
      deviceId: string | null;
      meetingKey: string;
      generation: number;
      reply: Reply;
    }
  | { kind: "acknowledge"; receiptId: number }
  /** The meeting's ending grace ran out. */
  | { kind: "ending"; meetingKey: string; generation: number }
  /** The ends of the steps the fiber started. */
  | {
      kind: "started";
      generation: number;
      meeting: MeetingPresenceMeeting;
      exit: Exit.Exit<MeetingCaptureState, unknown>;
      reply: Reply | undefined;
    }
  | {
      kind: "stopped";
      generation: number;
      meeting: MeetingPresenceMeeting;
      exit: Exit.Exit<StopResult, unknown>;
      reply: Reply | undefined;
    }
  | {
      kind: "stepped";
      generation: number;
      action: "pause" | "resume" | "discard";
      meeting: MeetingPresenceMeeting;
      exit: Exit.Exit<MeetingCaptureState, unknown>;
      reply: Reply | undefined;
    }
  | {
      kind: "microphoneChanged";
      generation: number;
      exit: Exit.Exit<MeetingCaptureState, unknown>;
      reply: Reply;
    }
  | {
      kind: "finalized";
      generation: number;
      receiptId: number;
      exit: Exit.Exit<MeetingTaskReceipt, unknown>;
    };

function message(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

/** What a failed step failed with. */
const failure = (exit: Exit.Failure<unknown, unknown>) => Cause.squash(exit.cause);

const unavailable = () =>
  Effect.fail(new CoreError("unavailable", "Meeting recording is unavailable here."));

/** The topic with no meeting recorder (a host without Main's parts: the web). */
export function registerNoMeetingRecorder(ctx: Ctx): void {
  ctx.kernel.source("meetingRecorder", {
    start() {},
    stop() {},
    compute: (): Value => ({ ok: unavailableMeetingRecorder }),
  });
  ctx.kernel.calls({
    "meetingRecorder.action": { run: unavailable },
    "meetingRecorder.selectMicrophone": { run: unavailable },
    "meetingRecorder.retryTaskSync": {
      run: () => Effect.succeed(unavailableMeetingRecorder),
    },
    "meetingRecorder.acknowledgeSaved": { run: () => Effect.succeed(null) },
  });
}

export class MeetingRecorder {
  readonly #ctx: Ctx;
  readonly #ports: MeetingPorts;
  readonly tasks: MeetingTasks;
  readonly #scope: Scoped;
  readonly #inputs = Effect.runSync(Queue.unbounded<Input>());
  // The fiber's own: only it writes these.
  #snapshot: MeetingRecorderValue = { ...unavailableMeetingRecorder };
  #preferences: MeetingPreferences = defaultPreferences;
  #meetings: MeetingPresenceMeeting[] = [];
  /** Meetings the person (or Auto) answered: not offered again while present. */
  #answered = new Set<string>();
  #initialized = false;
  /** The capture is this recorder's (it started it). */
  #owned = false;
  /** A step runs: other controls wait for it to end. */
  #busy = false;
  #generation = 0;
  #receipt = 0;
  #savedMeetingKey: string | undefined;
  #ending: Fiber.Fiber<unknown, unknown> | undefined;
  #account: string | undefined;
  #closed = false;
  /** Answers the input in turn owes its callers; the fiber settles them once the input is taken. */
  #answers: [Reply, Exit.Exit<MeetingRecorderValue, CoreError>][] = [];

  /** `locale`: the language a new meeting's Task is named in. */
  constructor(ctx: Ctx, ports: MeetingPorts, locale: () => CommaLocale) {
    this.#ctx = ctx;
    this.#ports = ports;
    this.#scope = ctx.runner.child();
    this.tasks = new MeetingTasks(
      ctx,
      ports,
      (key, state) => this.#offer({ kind: "task", key, state }),
      locale
    );
    this.#account = this.#userId();
    ctx.kernel.source("meetingRecorder", {
      start() {},
      stop() {},
      compute: (): Value => ({ ok: this.#snapshot }),
    });
    ctx.kernel.calls({
      "meetingRecorder.action": {
        run: (p) =>
          Effect.suspend(() => {
            const { action, meetingKey, generation } = (p ?? {}) as Record<
              string,
              unknown
            >;
            if (
              !ACTIONS.has(action as MeetingRecorderAction) ||
              typeof meetingKey !== "string" ||
              typeof generation !== "number"
            )
              return Effect.fail(
                CoreError.invalid("action, meetingKey and generation")
              );
            return this.#ask((reply) => ({
              kind: "action",
              action: action as MeetingRecorderAction,
              meetingKey,
              generation,
              reply,
            }));
          }),
      },
      "meetingRecorder.selectMicrophone": {
        run: (p) =>
          Effect.suspend(() => {
            const { deviceId, meetingKey, generation } = (p ?? {}) as Record<
              string,
              unknown
            >;
            if (
              (deviceId !== null && typeof deviceId !== "string") ||
              typeof meetingKey !== "string" ||
              typeof generation !== "number"
            )
              return Effect.fail(
                CoreError.invalid("deviceId, meetingKey and generation")
              );
            return this.#ask((reply) => ({
              kind: "microphone",
              deviceId,
              meetingKey,
              generation,
              reply,
            }));
          }),
      },
      "meetingRecorder.retryTaskSync": {
        run: () =>
          Effect.ignore(this.tasks.retryPending()).pipe(
            Effect.map(() => this.#snapshot)
          ),
      },
      "meetingRecorder.acknowledgeSaved": {
        run: (p) =>
          Effect.sync(() => {
            const receiptId = (p as { receiptId?: unknown } | null)?.receiptId;
            if (typeof receiptId !== "number") throw CoreError.invalid("receiptId");
            this.#offer({ kind: "acknowledge", receiptId });
            return null;
          }),
      },
    });
    ports.listen((event) => this.#offer({ kind: "event", event }));
    ctx.session.onChange(() => this.#offer({ kind: "session" }));
    ctx.runner.fork(
      Stream.fromQueue(this.#inputs).pipe(
        Stream.runForEach((input) =>
          Effect.suspend(() => {
            this.#take(input);
            return Effect.forEach(
              this.#answers.splice(0),
              ([reply, exit]) => Deferred.done(reply, exit),
              { discard: true }
            );
          })
        )
      ),
      this.#scope
    );
  }

  value(): MeetingRecorderValue {
    return this.#snapshot;
  }

  close(): void {
    this.#closed = true;
    this.tasks.close();
    this.#ctx.runner.close(this.#scope);
  }

  #offer(input: Input): void {
    if (!this.#closed) Queue.offerUnsafe(this.#inputs, input);
  }

  #ask(input: (reply: Reply) => Input): Effect.Effect<MeetingRecorderValue, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const reply = yield* Deferred.make<MeetingRecorderValue, CoreError>();
      this.#offer(input(reply));
      return yield* Deferred.await(reply);
    });
  }

  /** Runs `effect` as a step of its own (in the recorder's scope); its end comes back as an input. */
  #step<A, E>(
    effect: Effect.Effect<A, E>,
    end: (exit: Exit.Exit<A, E>) => Input
  ): void {
    this.#ctx.runner.fork(
      effect.pipe(
        Effect.exit,
        Effect.map((exit) => this.#offer(end(exit)))
      ),
      this.#scope
    );
  }

  /** Runs a Task lane command on its own; its failure comes back as the meeting's Task sync error. */
  #task(key: string, effect: Effect.Effect<unknown, unknown>): void {
    this.#ctx.runner.fork(
      effect.pipe(
        Effect.catch((error: unknown) =>
          Effect.sync(() => this.#offer({ kind: "taskError", key, error }))
        )
      ),
      this.#scope
    );
  }

  #userId(): string | undefined {
    const value = this.#ctx.session.value();
    return value.phase === "signed_in" ? value.userId : undefined;
  }

  /** One input, start to end (nothing here waits: what waits is a step). */
  #take(input: Input): void {
    if (this.#closed) return;
    switch (input.kind) {
      case "event":
        return this.#event(input.event);
      case "session":
        return this.#sessionChanged();
      case "task":
        return this.#acceptTask(input.key, input.state);
      case "taskError":
        return this.#taskError(input.error, input.key);
      case "action":
        return this.#action(input);
      case "ending":
        this.#ending = undefined;
        return this.#action({ ...input, kind: "action", action: "stop" });
      case "microphone":
        return this.#microphone(input);
      case "acknowledge":
        if (
          this.#snapshot.clientVisible &&
          this.#snapshot.saved?.receiptId === input.receiptId
        )
          this.#set({ saved: null });
        return;
      case "started":
        return this.#started(input);
      case "stopped":
        return this.#stopped(input);
      case "stepped":
        return this.#stepped(input);
      case "microphoneChanged":
        return this.#microphoneChanged(input);
      case "finalized":
        return this.#finalized(input);
    }
  }

  #event(event: MeetingEvent): void {
    switch (event.kind) {
      case "presence": {
        this.#meetings = event.state.meetings;
        if (this.#initialized) {
          const seen = new Set(event.state.meetings.map((m) => m.key));
          this.#answered = new Set([...this.#answered].filter((key) => seen.has(key)));
          this.#updateEnding();
        }
        // The first presence snapshot follows the same saved policy as later meetings.
        this.#initialized = true;
        this.#offerMeeting();
        return;
      }
      case "capture":
        this.#acceptCapture(event.state, event.meetingKey);
        return;
      case "preferences":
        this.#preferences = event.preferences;
        this.#set({});
        this.#offerMeeting();
        return;
      case "clientVisible":
        this.#set({ clientVisible: event.visible });
    }
  }

  #acceptCapture(capture: MeetingCaptureState, meetingKey?: string): void {
    // A capture Main started for a meeting before this core ran (the core restarted): it is this recorder's again.
    if (
      !this.#owned &&
      !this.#busy &&
      meetingKey &&
      (capture.status === "recording" || capture.status === "paused") &&
      this.#userId()
    ) {
      const meeting = this.#meetings.find((m) => m.key === meetingKey);
      if (meeting) {
        this.#owned = true;
        this.#answered.add(meetingKey);
        this.#set({ meeting, phase: capture.status, capture });
        this.#updateEnding();
        return;
      }
    }
    const phase =
      this.#owned &&
      (capture.status === "recording" || capture.status === "paused") &&
      (this.#snapshot.phase === "recording" || this.#snapshot.phase === "paused")
        ? capture.status
        : this.#snapshot.phase;
    this.#set({ capture, phase });
    if (this.#owned && capture.capped && this.#snapshot.meeting)
      this.#action({
        kind: "action",
        action: "stop",
        meetingKey: this.#snapshot.meeting.key,
        generation: this.#generation,
      });
    if (this.#owned && !this.#busy && capture.status === "idle") {
      this.#owned = false;
      this.#set({ phase: "idle", meeting: null });
    }
  }

  #sessionChanged(): void {
    if (this.#ctx.session.lease())
      this.#ctx.runner.fork(Effect.ignore(this.tasks.retryPending()), this.#scope);
    const account = this.#userId();
    if (account === this.#account) {
      this.#offerMeeting();
      return;
    }
    this.#account = account;
    this.#generation++;
    this.#clearEnding();
    if (this.#owned)
      this.#ctx.runner.fork(
        Effect.ignore(meetingCommand(this.#ports, "cancel", null)),
        this.#scope
      );
    this.#owned = false;
    this.#set({
      phase: "idle",
      meeting: null,
      saved: null,
      error: undefined,
      generation: this.#generation,
    });
    this.#offerMeeting();
  }

  #acceptTask(key: string, taskSync: MeetingTaskState): void {
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

  /** A person's (or Auto's, or the ending grace's) control of the meeting shown. */
  #action(input: Extract<Input, { kind: "action" }>): void {
    const { action, meetingKey, generation, reply } = input;
    const answer = () => {
      if (reply) this.#answer(reply);
    };
    const meeting = this.#snapshot.meeting;
    if (
      generation !== this.#generation ||
      !meeting ||
      meeting.key !== meetingKey ||
      this.#busy
    )
      return answer();
    if (action === "dismiss") {
      if (!this.#owned) {
        this.#task(meeting.key, this.tasks.change(meeting, "dismiss"));
        this.#answered.add(meetingKey);
        this.#set({ phase: "idle", meeting: null, error: undefined });
        this.#offerMeeting();
      }
      return answer();
    }
    if (
      action === "start" ? this.#owned || this.#answered.has(meetingKey) : !this.#owned
    )
      return answer();
    const lease = this.#ctx.session.lease();
    if (!this.#userId() || !lease) return answer();
    this.#busy = true;
    this.#set({ error: undefined });
    switch (action) {
      case "start": {
        this.#answered.add(meetingKey);
        this.#set({ phase: "starting" });
        // Owner-approved Recappi-style mix. Meeting identity controls the queue,
        // while the source includes system output rather than isolating a tab.
        const tasks = this.tasks;
        const ports = this.#ports;
        this.#step(
          Effect.gen({ self: this }, function* () {
            yield* tasks
              .enter(meeting)
              .pipe(
                Effect.catch((error) =>
                  Effect.sync(() =>
                    this.#offer({ kind: "taskError", key: meeting.key, error })
                  )
                )
              );
            // Audio remains available when Task sync is blocked.
            const archiveAtMs = yield* tasks
              .archiveTime(meeting.key)
              .pipe(Effect.orElseSucceed(() => undefined));
            return yield* meetingCommand(ports, "start", {
              lease,
              meeting,
              ...(archiveAtMs !== undefined ? { archiveAtMs } : {}),
            });
          }),
          (exit) => ({ kind: "started", generation, meeting, exit, reply })
        );
        return;
      }
      case "stop":
        this.#clearEnding();
        this.#set({ phase: "saving" });
        this.#step(meetingCommand(this.#ports, "stop", { lease }), (exit) => ({
          kind: "stopped",
          generation,
          meeting,
          exit,
          reply,
        }));
        return;
      case "discard":
        this.#step(
          meetingCommand(this.#ports, "cancel", null).pipe(
            Effect.tap(() =>
              this.tasks
                .change(meeting, "discard")
                .pipe(
                  Effect.catch((error) =>
                    Effect.sync(() =>
                      this.#offer({ kind: "taskError", key: meeting.key, error })
                    )
                  )
                )
            )
          ),
          (exit) => ({ kind: "stepped", generation, action, meeting, exit, reply })
        );
        return;
      case "pause":
      case "resume":
        this.#step(meetingCommand(this.#ports, action, null), (exit) => ({
          kind: "stepped",
          generation,
          action,
          meeting,
          exit,
          reply,
        }));
    }
  }

  #started(input: Extract<Input, { kind: "started" }>): void {
    const { exit, meeting, generation } = input;
    if (generation !== this.#generation) {
      // The account changed while capture opened: what opened is let go.
      this.#ctx.runner.fork(
        Effect.ignore(meetingCommand(this.#ports, "cancel", null)),
        this.#scope
      );
      return this.#ended(input.reply);
    }
    if (Exit.isFailure(exit)) return this.#failed(failure(exit), input.reply);
    if (exit.value.status !== "recording")
      return this.#failed(
        new Error(exit.value.reason ?? "Recording could not start."),
        input.reply
      );
    this.#owned = true;
    this.#set({ phase: "recording", capture: exit.value });
    this.#task(meeting.key, this.tasks.change(meeting, "recording"));
    this.#ended(input.reply);
  }

  #stopped(input: Extract<Input, { kind: "stopped" }>): void {
    const { exit, meeting, generation } = input;
    this.#owned = false;
    if (generation !== this.#generation) return this.#ended(input.reply);
    if (Exit.isFailure(exit)) return this.#failed(failure(exit), input.reply);
    const result = exit.value;
    if (result.status !== "ready")
      return this.#failed(
        new Error(result.reason ?? "Recording could not be saved to Drive."),
        input.reply
      );
    const smartSummary = this.#preferences.meetingSmartSummary;
    this.#savedMeetingKey = meeting.key;
    const receiptId = ++this.#receipt;
    this.#set({
      phase: "idle",
      meeting: null,
      saved: {
        receiptId,
        recording: result.recording,
        smartSummary,
        ...(this.#snapshot.taskSync?.task
          ? { task: this.#snapshot.taskSync.task }
          : {}),
        summary: "pending",
      },
    });
    // The meeting's audio goes to its Task on the lane; the receipt says how that went.
    this.#step(
      this.tasks.finalize(
        meeting.key,
        result.recording,
        result.sourcePath,
        smartSummary
      ),
      (done) => ({ kind: "finalized", generation, receiptId, exit: done })
    );
    this.#ended(input.reply);
  }

  #stepped(input: Extract<Input, { kind: "stepped" }>): void {
    const { exit, meeting, generation, action } = input;
    if (Exit.isFailure(exit)) return this.#failed(failure(exit), input.reply);
    if (action === "discard") {
      this.#owned = false;
      this.#clearEnding();
      if (generation === this.#generation) this.#set({ phase: "idle", meeting: null });
    } else if (generation === this.#generation) {
      this.#acceptCapture(exit.value);
      this.#task(
        meeting.key,
        this.tasks.change(meeting, action === "pause" ? "paused" : "recording")
      );
    }
    this.#ended(input.reply);
  }

  #finalized(input: Extract<Input, { kind: "finalized" }>): void {
    const saved = this.#snapshot.saved;
    if (input.generation !== this.#generation || saved?.receiptId !== input.receiptId)
      return;
    const exit = input.exit;
    this.#set({
      saved: Exit.isSuccess(exit)
        ? {
            ...saved,
            summary: "queued",
            summaryError: undefined,
            task: { groupId: exit.value.group_id, taskId: exit.value.task_id },
          }
        : {
            ...saved,
            summary: "error",
            summaryError:
              saved.summaryError ?? meetingSubmissionError("prepare", failure(exit)),
          },
    });
  }

  #microphone(input: Extract<Input, { kind: "microphone" }>): void {
    const lease = this.#ctx.session.lease();
    if (
      input.generation !== this.#generation ||
      !this.#owned ||
      this.#busy ||
      this.#snapshot.meeting?.key !== input.meetingKey ||
      !lease
    ) {
      this.#answer(input.reply);
      return;
    }
    // Stop can invalidate a pending device switch. Do not serialize Stop
    // behind permission/device opening.
    this.#step(
      meetingCommand(this.#ports, "selectMicrophone", {
        lease,
        deviceId: input.deviceId,
      }),
      (exit) => ({
        kind: "microphoneChanged",
        generation: input.generation,
        exit,
        reply: input.reply,
      })
    );
  }

  #microphoneChanged(input: Extract<Input, { kind: "microphoneChanged" }>): void {
    const { exit } = input;
    if (Exit.isFailure(exit)) {
      this.#answers.push([
        input.reply,
        Exit.fail(
          new CoreError(
            "failed",
            message(failure(exit), "The microphone could not change.")
          )
        ),
      ]);
      return;
    }
    if (
      input.generation === this.#generation &&
      this.#owned &&
      (this.#snapshot.phase === "recording" || this.#snapshot.phase === "paused")
    )
      this.#acceptCapture(exit.value);
    this.#answer(input.reply);
  }

  /** A step failed: the capture stays shown while it still runs, else the error. */
  #failed(error: unknown, reply: Reply | undefined): void {
    this.#set({
      phase:
        this.#owned &&
        (this.#snapshot.capture.status === "recording" ||
          this.#snapshot.capture.status === "paused")
          ? this.#snapshot.capture.status
          : "error",
      error: message(error, "Recording failed."),
    });
    this.#ended(reply);
  }

  /** A step ended: other controls may act, a meeting may be offered, the ending grace may run. */
  #ended(reply: Reply | undefined): void {
    this.#busy = false;
    if (!this.#owned) this.#offerMeeting();
    this.#updateEnding();
    if (reply) this.#answer(reply);
  }

  /** The caller's answer: the recorder as it is now. */
  #answer(reply: Reply): void {
    this.#answers.push([reply, Exit.succeed(this.#snapshot)]);
  }

  #set(patch: Partial<MeetingRecorderValue>): void {
    const next = {
      ...this.#snapshot,
      ...patch,
      hideRecorder: this.#preferences.meetingHideRecorder,
      revision: this.#snapshot.revision,
    };
    // A change that changes nothing is no new revision (two paths may say the same).
    if (JSON.stringify(next) === JSON.stringify(this.#snapshot)) return;
    this.#snapshot = { ...next, revision: next.revision + 1 };
    this.#ctx.kernel.store.invalidate({ topic: "meetingRecorder" });
  }

  #offerMeeting(): void {
    if (
      !this.#initialized ||
      this.#owned ||
      this.#busy ||
      !this.#userId() ||
      this.#snapshot.phase === "error"
    )
      return;
    const meeting = this.#meetings.find(
      (m) => m.status === "active" && !this.#answered.has(m.key)
    );
    const previous = this.#snapshot.meeting;
    const automatic =
      meeting &&
      this.#preferences.meetingStartRecording === "auto" &&
      !["recording", "paused", "finalizing"].includes(this.#snapshot.capture.status);
    const entered = meeting && previous?.key !== meeting.key;
    if (
      previous &&
      previous.key !== meeting?.key &&
      this.#snapshot.phase === "detected"
    )
      this.#task(previous.key, this.tasks.change(previous, "dismiss"));
    this.#set({
      ...(entered ? { taskSync: { status: "pending" as const } } : {}),
      meeting: meeting ?? null,
      phase: meeting && !automatic ? "detected" : "idle",
    });
    if (meeting && entered) this.#task(meeting.key, this.tasks.enter(meeting));
    if (automatic)
      this.#action({
        kind: "action",
        action: "start",
        meetingKey: meeting.key,
        generation: this.#generation,
      });
  }

  #taskError(error: unknown, key: string): void {
    if (this.#snapshot.meeting?.key !== key) return;
    this.#set({
      taskSync: {
        ...this.#snapshot.taskSync,
        status: "error",
        error: message(error, "Meeting sync failed."),
      },
    });
  }

  #clearEnding(): void {
    if (this.#ending) this.#ctx.runner.interrupt(this.#ending);
    this.#ending = undefined;
  }

  #updateEnding(): void {
    if (!this.#owned || this.#busy) return;
    const meeting = this.#snapshot.meeting;
    if (!meeting) return;
    const current = this.#meetings.find((m) => m.key === meeting.key);
    if (current?.status === "active") {
      this.#clearEnding();
      return;
    }
    if (this.#ending) return;
    // One timer per capture; no per-meeting polling or fan-out.
    const generation = this.#generation;
    this.#ending = this.#ctx.runner.fork(
      Effect.sleep(Duration.millis(current ? ENDING_GRACE_MS : 0)).pipe(
        Effect.map(() =>
          this.#offer({ kind: "ending", meetingKey: meeting.key, generation })
        )
      ),
      this.#scope
    ) as Fiber.Fiber<unknown, unknown>;
  }
}
