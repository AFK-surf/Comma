// One Task per meeting: a bounded, durable command lane for the meeting's entry, its controls (recording, paused,
// dismiss, discard) and its saved audio (finalize), kept in device storage (`meeting-tasks`) across restarts and
// accounts. Each command carries the version it was saved with, and a resend sends the saved command again with the
// same identifiers, so the server applies it once.
//
// One fiber, the lane, owns the journal: it takes the lane's commands from one queue in turn, saves each before it
// answers its caller, then sends what the meeting saved. Commands are serialized by construction: nothing else writes
// the journal. A finalize that failed in a way a later try may fix is tried twice more, 5 s and 15 s after (a
// `Schedule` on the core's Clock), for the session it failed in. Outputs of a summarized meeting are archived by their
// own two workers (outputs.ts), which report to the lane.
//
// Bounds: at most 32 retained meetings; one send at a time; two delayed retries of a failed finalize; a question about
// a meeting found after a restart holds the lane until it is answered.
import {
  CoreError,
  fromUtf8,
  type HostError,
  type Scoped,
  utf8,
} from "@comma/core-kernel";
import { type CommaLocale, formatDate, messages } from "@comma/i18n";
import {
  Cause,
  DateTime,
  Deferred,
  Duration,
  Effect,
  Exit,
  type Fiber,
  Option,
  Queue,
  Schedule,
  Stream,
} from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import { workspaceBootstrapSchema } from "../comma/schemas.ts";
import type { Ctx } from "../ctx.ts";
import type {
  MeetingLocalFile,
  MeetingPorts,
  MeetingPresenceMeeting,
  MeetingRecording,
  SessionLease,
} from "../host.ts";
import {
  canRetryMeetingSubmission,
  meetingSubmissionError,
  type MeetingSubmissionStage,
} from "./errors.ts";
import {
  archiveMeetingOutputs,
  meetingOutputExtensions,
  type MeetingOutputJob,
} from "./outputs.ts";
import { meetingCommand } from "./ports.ts";

/** Where the journal is kept on the device. */
export const MEETING_JOURNAL_KEY = "meeting-tasks";

export const meetingTaskReceiptSchema = z.object({
  group_id: z.string(),
  task_id: z.string(),
  status: z.string(),
  meeting: z
    .object({
      occurrence_id: z.string(),
      name: z.string(),
      archive_date: z.string(),
      started_at: z.number(),
      phase: z.enum([
        "awaiting_recording",
        "recording",
        "paused",
        "dismissed",
        "discarded",
        "saving",
        "processing",
        "saved",
      ]),
      version: z.number().int().nonnegative(),
    })
    .strip(),
});
export type MeetingTaskReceipt = z.infer<typeof meetingTaskReceiptSchema>;

type MeetingTaskCommand = { version: number } & (
  | { action: "recording" | "paused" | "dismiss" | "discard" }
  | {
      action: "finalize";
      smart_summary: boolean;
      recording: {
        recording_id: string;
        durationMs: number;
        driveFile: { space: string; path: string };
      };
      file: { localFileRef: string; name: string; mediaType: string; size: number };
    }
);

const recordingSchema = z
  .object({
    channels: z.number(),
    durationMs: z.number(),
    driveFile: z.object({ space: z.string(), path: z.string() }),
    file: z.object({
      mediaType: z.enum(["audio/wav", "audio/mp4"]),
      name: z.string(),
      size: z.number(),
    }),
    sampleRate: z.number(),
  })
  .strip();

const entrySchema = z.object({
  /** `${audience}:${userId}`: whose meeting it is. */
  account: z.string(),
  /** The presence key of the meeting it was entered for (it moves to a replacement). */
  key: z.string(),
  app: z.string(),
  entry: z.object({
    occurrence_id: z.string(),
    name: z.string(),
    started_at: z.number(),
    archive_date: z.string(),
  }),
  workspace: z.object({ id: z.string(), group_id: z.string() }).optional(),
  receipt: meetingTaskReceiptSchema.optional(),
  file: z
    .object({
      localFileRef: z.string(),
      mediaType: z.string(),
      name: z.string(),
      size: z.number(),
    })
    .strip()
    .optional(),
  outputs: z.array(z.enum(meetingOutputExtensions)).max(3).default([]),
  version: z.number().int().nonnegative(),
  action: z.enum(["recording", "paused", "dismiss", "discard", "finalize"]).optional(),
  final: z
    .object({
      recording: recordingSchema,
      /** The saved recording's local copy, as Main named it (only Main reads it). */
      sourcePath: z.string(),
      recordingId: z.string(),
      smartSummary: z.boolean(),
    })
    .optional(),
});
type Entry = z.infer<typeof entrySchema>;
const journalSchema = z.array(entrySchema).max(32);

/** A meeting's Task as the recorder shows it. */
export type MeetingTaskState = {
  task?: { groupId: string; taskId: string };
  status: "pending" | "synced" | "error";
  error?: string;
  archive?: "done" | "error";
  recording?: MeetingRecording;
};

/** A meeting command's failure, as a person reads it; `retryable` when a later try may succeed on its own. */
export class MeetingTaskError extends Error {
  readonly retryable: boolean;

  constructor(message: string, retryable = false) {
    super(message);
    this.retryable = retryable;
  }
}

/** A failed finalize, tried again twice: 5 s and 15 s after. */
const RETRY = { schedule: Schedule.exponential(Duration.seconds(5), 3), times: 2 };

type Reply<A> = Deferred.Deferred<A, MeetingTaskError>;
type Command =
  | { kind: "enter"; meeting: MeetingPresenceMeeting; reply: Reply<void> }
  | {
      kind: "change";
      meeting: MeetingPresenceMeeting;
      action: "recording" | "paused" | "dismiss" | "discard";
      reply: Reply<void>;
    }
  | {
      kind: "finalize";
      key: string;
      recording: MeetingRecording;
      sourcePath: string;
      smartSummary: boolean;
      reply: Reply<MeetingTaskReceipt>;
    }
  | { kind: "archiveTime"; key: string; reply: Reply<number | undefined> }
  | { kind: "retry"; reply: Reply<void> }
  /** A scheduled retry of a failed finalize, for the session it failed in. */
  | {
      kind: "resend";
      id: string;
      lease: SessionLease;
      reply: Reply<MeetingTaskReceipt>;
    }
  /** The outputs saved so far (an archive worker's checkpoint). */
  | { kind: "checkpoint"; job: MeetingOutputJob; reply: Reply<void> }
  /** An archive worker ended its job. */
  | { kind: "archived"; job: MeetingOutputJob; done: boolean };

/** The server archives a dismissed meeting and cancels a discarded one. It rejects every newer command. */
function closedWithoutAudio(entry: Entry): boolean {
  const phase = entry.receipt?.meeting.phase;
  return !entry.final && (phase === "dismissed" || phase === "discarded");
}

/**
 * A new meeting's Task title: when the meeting started, after its platform's name. Another browser's name is no
 * meeting's platform (only Comma's browser knows its page's), so that title has the time alone. The summary's
 * heading replaces it (outputs.ts).
 */
function meetingTitle(
  meeting: MeetingPresenceMeeting,
  startedAt: number,
  locale: CommaLocale
): string {
  const time = formatDate(startedAt, locale, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
  return meeting.kind === "browser" && !meeting.browserTabId
    ? messages.meeting_task_title({ time }, { locale })
    : messages.meeting_task_title_app({ app: meeting.name, time }, { locale });
}

function sameLease(a: SessionLease, b: SessionLease | null): boolean {
  return (
    b !== null &&
    a.audience === b.audience &&
    a.authorityInstanceId === b.authorityInstanceId &&
    a.generation === b.generation &&
    a.sessionId === b.sessionId
  );
}

/** The archive workers, for one account: the jobs they hold, and the ids held. */
interface Outputs {
  account: string;
  scope: Scoped;
  jobs: Queue.Queue<MeetingOutputJob>;
  held: Set<string>;
}

const asTaskError = (error: unknown) =>
  error instanceof MeetingTaskError
    ? error
    : new MeetingTaskError(error instanceof Error ? error.message : String(error));

export class MeetingTasks {
  readonly #ctx: Ctx;
  readonly #ports: MeetingPorts;
  readonly #publish: (key: string, state: MeetingTaskState) => void;
  readonly #locale: () => CommaLocale;
  readonly #scope: Scoped;
  readonly #commands = Effect.runSync(Queue.unbounded<Command>());
  // The lane's own: only its fiber reads or writes these.
  #entries: Entry[] = [];
  /** `${account}:${presence key}` → the occurrence that owns that key now. */
  readonly #current = new Map<string, string>();
  readonly #retries = new Map<string, Fiber.Fiber<unknown, unknown>>();
  #loadError: string | undefined;
  #outputs: Outputs | null = null;
  #closed = false;

  constructor(
    ctx: Ctx,
    ports: MeetingPorts,
    publish: (key: string, state: MeetingTaskState) => void,
    locale: () => CommaLocale
  ) {
    this.#ctx = ctx;
    this.#ports = ports;
    this.#publish = publish;
    this.#locale = locale;
    this.#scope = ctx.runner.child();
    ctx.runner.fork(
      this.#load().pipe(
        Effect.andThen(
          Stream.fromQueue(this.#commands).pipe(
            Stream.runForEach((command) => this.#handle(command))
          )
        )
      ),
      this.#scope
    );
  }

  /** The signed-in account as the journal names it (`${audience}:${userId}`). */
  account(): string | undefined {
    const value = this.#ctx.session.value();
    return value.phase === "signed_in"
      ? `${value.audience}:${value.userId}`
      : undefined;
  }

  /** The meeting `meeting` is in now: its Task entered (once per presence key), its entry saved before any request. */
  enter(meeting: MeetingPresenceMeeting): Effect.Effect<void, MeetingTaskError> {
    return this.#ask((reply) => ({ kind: "enter", meeting, reply }));
  }

  /** A control of the meeting: saved before it answers, then sent on the lane. */
  change(
    meeting: MeetingPresenceMeeting,
    action: "recording" | "paused" | "dismiss" | "discard"
  ): Effect.Effect<void, MeetingTaskError> {
    return this.#ask((reply) => ({ kind: "change", meeting, action, reply }));
  }

  /** The meeting's saved audio: kept with a recording id of its own, then delivered to its Task. */
  finalize(
    key: string,
    recording: MeetingRecording,
    sourcePath: string,
    smartSummary: boolean
  ): Effect.Effect<MeetingTaskReceipt, MeetingTaskError> {
    return this.#ask((reply) => ({
      kind: "finalize",
      key,
      recording,
      sourcePath,
      smartSummary,
      reply,
    }));
  }

  /** When the meeting started (its recording is archived on that day); none without a saved Task. */
  archiveTime(key: string): Effect.Effect<number | undefined, MeetingTaskError> {
    return this.#ask((reply) => ({ kind: "archiveTime", key, reply }));
  }

  /** Sends the account's saved commands that wait again, and archives outputs that wait. */
  retryPending(): Effect.Effect<void, MeetingTaskError> {
    return this.#ask((reply) => ({ kind: "retry", reply }));
  }

  close(): void {
    this.#closed = true;
    this.#ctx.runner.close(this.#scope);
  }

  #ask<A>(command: (reply: Reply<A>) => Command): Effect.Effect<A, MeetingTaskError> {
    return Effect.gen({ self: this }, function* () {
      if (this.#closed)
        return yield* Effect.fail(new MeetingTaskError("Meeting sync is closed."));
      const reply = yield* Deferred.make<A, MeetingTaskError>();
      yield* Queue.offer(this.#commands, command(reply));
      return yield* Deferred.await(reply);
    });
  }

  /** The journal from device storage, or once from the one Main kept before the core. */
  #load(): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const kept = yield* Effect.exit(ctx.host.storageGet(MEETING_JOURNAL_KEY));
      let text: string | null = "";
      let legacy = false;
      if (Exit.isSuccess(kept)) {
        if (kept.value) text = fromUtf8(kept.value);
        else {
          const old = yield* Effect.exit(meetingCommand(this.#ports, "legacy", null));
          text = Exit.isSuccess(old) ? old.value : "";
          legacy = true;
        }
      }
      if (text === null) return;
      const entries =
        text.length > 512_000
          ? Option.none()
          : yield* Effect.option(
              Effect.try(() => journalSchema.parse(JSON.parse(text)))
            );
      if (Option.isNone(entries)) {
        this.#loadError =
          "Saved meeting sync data could not be read. Audio recording remains available; restore the meeting journal before syncing Tasks.";
        return;
      }
      this.#entries = entries.value;
      // Main's journal is carried over once: from now on the device keeps it.
      if (legacy) yield* Effect.ignore(this.#persist());
    });
  }

  /** One command, start to end; what it fails with is its caller's. */
  #handle(command: Command): Effect.Effect<void> {
    const answer = <A>(reply: Reply<A>, effect: Effect.Effect<A, unknown>) =>
      effect.pipe(
        Effect.mapError(asTaskError),
        Effect.exit,
        Effect.flatMap((exit) => Deferred.done(reply, exit)),
        Effect.asVoid
      );
    switch (command.kind) {
      case "enter":
        return Effect.suspend(() => {
          const ready = this.#ready();
          if (ready) return answer(command.reply, ready);
          const key = `${this.account()}:${command.meeting.key}`;
          if (this.#current.has(key)) return answer(command.reply, Effect.void);
          return this.#enter(command.meeting).pipe(
            Effect.exit,
            Effect.flatMap((exit) =>
              Deferred.done(
                command.reply,
                Exit.isSuccess(exit)
                  ? Exit.void
                  : Exit.fail(asTaskError(Cause.squash(exit.cause)))
              ).pipe(
                Effect.andThen(
                  Exit.isSuccess(exit) ? this.#syncQuietly(exit.value) : Effect.void
                )
              )
            ),
            Effect.ignoreCause
          );
        });
      case "change":
        return this.#change(command);
      case "finalize":
        return answer(command.reply, this.#finalize(command));
      case "archiveTime":
        return answer(
          command.reply,
          Effect.sync(() => this.#get(command.key)?.entry.started_at)
        );
      case "retry":
        return answer(command.reply, this.#retryPending());
      case "resend":
        return answer(
          command.reply,
          Effect.suspend(() => {
            const entry = this.#entries.find(
              (e) => e.entry.occurrence_id === command.id
            );
            if (!entry || this.#closed || entry.account !== this.account())
              return Effect.fail(new MeetingTaskError("The meeting account changed."));
            this.#show(entry, "pending");
            return this.#sync(entry, { lease: command.lease });
          })
        );
      case "checkpoint":
        return answer(
          command.reply,
          Effect.suspend(() => {
            const entry = this.#entries.find(
              (e) => e.entry.occurrence_id === command.job.id
            );
            if (!entry) return Effect.void;
            entry.outputs = [...command.job.completed];
            return this.#persist();
          })
        );
      case "archived":
        return Effect.sync(() => {
          const { job } = command;
          this.#outputs?.held.delete(job.id);
          if (this.#closed || job.account !== this.account()) return;
          const entry = this.#entries.find((e) => e.entry.occurrence_id === job.id);
          if (entry)
            this.#publish(entry.key, {
              status: "synced",
              task: { groupId: job.groupId, taskId: job.taskId },
              archive: command.done && job.completed.length === 3 ? "done" : "error",
              recording: job.recording,
            });
        });
    }
  }

  /** Why the lane cannot take a meeting now, if it cannot. */
  #ready(): Effect.Effect<never, MeetingTaskError> | null {
    if (this.#loadError) return Effect.fail(new MeetingTaskError(this.#loadError));
    if (this.#closed)
      return Effect.fail(new MeetingTaskError("Meeting sync is closed."));
    if (!this.account())
      return Effect.fail(new MeetingTaskError("Sign in to sync this meeting."));
    return null;
  }

  /** Saves a new occurrence for `meeting` (or resumes the one before a restart, when the person says so). */
  #enter(
    meeting: MeetingPresenceMeeting,
    replaced?: Entry
  ): Effect.Effect<Entry, unknown> {
    return Effect.gen({ self: this }, function* () {
      const account = this.account()!;
      // A restarted detector cannot prove continuity. Ask before reusing its old Task.
      // A replaced occurrence keeps its live presence key, which proves continuity.
      const owned = new Set(this.#current.values());
      const prior = replaced
        ? undefined
        : this.#entries.find(
            (e) =>
              e.account === account &&
              e.app === meeting.name &&
              !e.final &&
              !closedWithoutAudio(e) &&
              e.action !== "dismiss" &&
              e.action !== "discard" &&
              !owned.has(e.entry.occurrence_id)
          );
      let entry: Entry | undefined;
      if (prior) {
        // Main asks whether this is the app's previous meeting.
        const answer = yield* meetingCommand(this.#ports, "recover", {
          name: prior.app,
        });
        if (answer === "resume") entry = prior;
        else if (!prior.action) {
          // The person declined the old unrecorded occurrence; preserve its archive command.
          prior.action = "dismiss";
          prior.version++;
          yield* this.#persist();
          yield* this.#syncQuietly(prior);
        }
      }
      if (this.account() !== account || this.#closed)
        return yield* Effect.fail(new MeetingTaskError("The meeting account changed."));
      if (!entry) {
        // The replaced occurrence keeps the key until its replacement is saved.
        this.#entries = this.#entries.filter(
          (e) =>
            e === replaced ||
            !(
              closedWithoutAudio(e) ||
              (e.receipt &&
                e.receipt.meeting.version === e.version &&
                (e.action === "dismiss" ||
                  e.action === "discard" ||
                  (e.action === "finalize" &&
                    (!e.final?.smartSummary || e.outputs.length === 3))))
            )
        );
        const retained = new Set(this.#entries.map((e) => e.entry.occurrence_id));
        for (const [currentKey, id] of this.#current)
          if (!retained.has(id)) this.#current.delete(currentKey);
        if (this.#entries.length >= 32)
          return yield* Effect.fail(
            new MeetingTaskError(
              "32 meetings are waiting to sync. Resolve them before creating another meeting Task."
            )
          );
        const now = DateTime.makeZonedUnsafe(this.#ctx.now(), {
          timeZone: DateTime.zoneMakeLocal(),
        });
        // The same meeting keeps its start time (so its title) and the archive date of its recording.
        const startedAt = replaced?.entry.started_at ?? DateTime.toEpochMillis(now);
        entry = {
          account,
          key: meeting.key,
          app: meeting.name,
          version: 0,
          outputs: [],
          entry: {
            occurrence_id: this.#uuid(),
            name: meetingTitle(meeting, startedAt, this.#locale()),
            started_at: startedAt,
            archive_date: replaced?.entry.archive_date ?? DateTime.formatIsoDate(now),
          },
        };
        this.#entries.push(entry);
      }
      const saved = entry;
      saved.key = meeting.key;
      yield* this.#persist();
      this.#current.set(`${account}:${meeting.key}`, saved.entry.occurrence_id);
      // The closed occurrence leaves the journal with the next write, now that its key moved.
      if (replaced && closedWithoutAudio(replaced))
        this.#entries = this.#entries.filter((e) => e !== replaced);
      this.#show(saved, "pending");
      return saved;
    });
  }

  #change(command: Extract<Command, { kind: "change" }>): Effect.Effect<void> {
    const { meeting, action, reply } = command;
    return Effect.gen({ self: this }, function* () {
      const ready = this.#ready();
      if (ready) return yield* ready;
      let entry = this.#get(meeting.key);
      if (!entry) {
        entry = yield* this.#enter(meeting);
        yield* this.#syncQuietly(entry);
      }
      if (entry.final) return null;
      if (
        entry.action === "dismiss" ||
        entry.action === "discard" ||
        closedWithoutAudio(entry)
      ) {
        // Presence can offer the same meeting again after its occurrence closed.
        if (action === "dismiss" || action === "discard") return null;
        entry = yield* this.#enter(meeting, entry);
      }
      entry.action = action;
      entry.version++;
      yield* this.#persist();
      this.#show(entry, "pending");
      return entry;
    }).pipe(
      Effect.exit,
      Effect.flatMap((exit) =>
        Deferred.done(
          reply,
          Exit.isSuccess(exit)
            ? Exit.void
            : Exit.fail(asTaskError(Cause.squash(exit.cause)))
        ).pipe(
          Effect.andThen(
            Exit.isSuccess(exit) && exit.value
              ? this.#syncQuietly(exit.value)
              : Effect.void
          )
        )
      ),
      Effect.ignoreCause
    );
  }

  #finalize(
    command: Extract<Command, { kind: "finalize" }>
  ): Effect.Effect<MeetingTaskReceipt, MeetingTaskError> {
    return Effect.gen({ self: this }, function* () {
      const entry = this.#get(command.key);
      if (!entry)
        return yield* Effect.fail(
          new MeetingTaskError("This meeting has no saved Task association.")
        );
      if (!entry.final) {
        entry.final = {
          recording: command.recording,
          sourcePath: command.sourcePath,
          smartSummary: command.smartSummary,
          recordingId: this.#uuid(),
        };
        entry.action = "finalize";
        entry.version++;
        const saved = yield* Effect.exit(this.#persist());
        if (Exit.isFailure(saved)) {
          const message = meetingSubmissionError("journal", saved.cause);
          this.#show(entry, "error", message);
          this.#report(entry, "journal", message);
          return yield* Effect.fail(new MeetingTaskError(message));
        }
      }
      this.#show(entry, "pending");
      return yield* this.#sync(entry, { schedule: true });
    });
  }

  #retryPending(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#loadError || this.#closed) return;
      const account = this.account();
      // Archive workers of another account stop, without writing what they read.
      if (this.#outputs && this.#outputs.account !== account) {
        this.#ctx.runner.close(this.#outputs.scope);
        this.#outputs = null;
      }
      for (const entry of this.#entries)
        if (entry.account === account) this.#watchOutputs(entry);
      const pending = this.#entries.filter(
        (entry) =>
          entry.account === account &&
          !closedWithoutAudio(entry) &&
          (!entry.receipt ||
            entry.receipt.meeting.version < entry.version ||
            entry.receipt.meeting.phase === "saving")
      );
      for (const entry of pending)
        yield* Effect.exit(this.#sync(entry, { schedule: true }));
    });
  }

  #get(key: string): Entry | undefined {
    const id = this.#current.get(`${this.account()}:${key}`);
    return this.#entries.find((e) => e.entry.occurrence_id === id);
  }

  /** The journal as it is now, in device storage. */
  #persist(): Effect.Effect<void, HostError> {
    return Effect.suspend(() =>
      this.#ctx.host.storageSet(
        MEETING_JOURNAL_KEY,
        utf8(JSON.stringify(this.#entries))
      )
    );
  }

  #uuid(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  #show(entry: Entry, status: MeetingTaskState["status"], error?: string): void {
    if (entry.account !== this.account() || this.#closed) return;
    // Only the occurrence that owns the key publishes. A closed occurrence without a key
    // has no view, and its late result must not overwrite a replacement's saved card.
    const owner = this.#current.get(`${entry.account}:${entry.key}`);
    const closed =
      entry.action === "dismiss" ||
      entry.action === "discard" ||
      closedWithoutAudio(entry);
    if (owner ? owner !== entry.entry.occurrence_id : closed) return;
    this.#publish(entry.key, {
      status,
      ...(entry.receipt
        ? { task: { groupId: entry.receipt.group_id, taskId: entry.receipt.task_id } }
        : {}),
      ...(error ? { error } : {}),
    });
  }

  #report(entry: Entry, stage: MeetingSubmissionStage, message: string): void {
    console.warn("Meeting submission failed", {
      occurrenceId: entry.entry.occurrence_id,
      version: entry.version,
      stage,
      message,
    });
  }

  /** A summarized meeting's outputs, to the archive workers (one job per meeting at a time). */
  #watchOutputs(entry: Entry): void {
    if (
      !entry.final?.smartSummary ||
      !entry.receipt ||
      entry.receipt.meeting.phase !== "processing" ||
      entry.outputs.length === 3 ||
      entry.account !== this.account()
    )
      return;
    const outputs = this.#outputs ?? this.#startOutputs(entry.account);
    if (outputs.held.has(entry.entry.occurrence_id)) return;
    outputs.held.add(entry.entry.occurrence_id);
    Queue.offerUnsafe(outputs.jobs, {
      id: entry.entry.occurrence_id,
      account: entry.account,
      groupId: entry.receipt.group_id,
      taskId: entry.receipt.task_id,
      title: entry.entry.name,
      recording: entry.final.recording,
      completed: [...entry.outputs],
    });
  }

  /** Two archive workers for `account`'s jobs: each job reports its checkpoints and its end to the lane. */
  #startOutputs(account: string): Outputs {
    const scope = this.#ctx.runner.child(this.#scope);
    const jobs = Effect.runSync(Queue.unbounded<MeetingOutputJob>());
    const outputs = { account, scope, jobs, held: new Set<string>() };
    this.#outputs = outputs;
    this.#ctx.runner.fork(
      Stream.fromQueue(jobs).pipe(
        Stream.mapEffect(
          (job) =>
            archiveMeetingOutputs(this.#ctx, this.#ports, job, () =>
              this.#ask((reply) => ({ kind: "checkpoint", job, reply }))
            ).pipe(
              Effect.exit,
              Effect.map((exit) =>
                Queue.offerUnsafe(this.#commands, {
                  kind: "archived",
                  job,
                  done: Exit.isSuccess(exit),
                })
              )
            ),
          { concurrency: 2, unordered: true }
        ),
        Stream.runDrain
      ),
      scope
    );
    return outputs;
  }

  /** Sends what `entry` saved; its failure is published, not thrown. */
  #syncQuietly(entry: Entry): Effect.Effect<void> {
    return Effect.ignore(this.#sync(entry, { schedule: true }));
  }

  /**
   * Sends what `entry` saved. `schedule`: a finalize that fails in a way a later try may fix is tried again on its own
   * (any earlier such retry of it ends: this send is newer). `lease`: a scheduled retry, sent only for that session.
   */
  #sync(
    entry: Entry,
    options: { schedule?: boolean; lease?: SessionLease }
  ): Effect.Effect<MeetingTaskReceipt, MeetingTaskError> {
    const ctx = this.#ctx;
    const id = entry.entry.occurrence_id;
    if (options.schedule) {
      const retry = this.#retries.get(id);
      if (retry) ctx.runner.interrupt(retry);
      this.#retries.delete(id);
    }
    let stage: MeetingSubmissionStage = "prepare";
    let lease: SessionLease | undefined;
    const send = Effect.gen({ self: this }, function* () {
      if (this.#closed || entry.account !== this.account())
        return yield* Effect.fail(new MeetingTaskError("The meeting account changed."));
      const account: Account = yield* ctx.session.account();
      if (`${account.lease.audience}:${account.userId}` !== entry.account)
        return yield* Effect.fail(new MeetingTaskError("The meeting account changed."));
      // A scheduled retry goes only for the session it was scheduled in.
      if (options.lease && !sameLease(options.lease, account.lease))
        return yield* Effect.fail(new CoreError("signed_out", "The session changed."));
      const current = account.lease;
      lease = current;
      if (!entry.workspace) {
        const bootstrap = yield* ctx.api.request(
          account,
          "POST",
          route`/v1/comma/me/bootstrap`,
          workspaceBootstrapSchema,
          {}
        );
        if (bootstrap.status !== "ready")
          return yield* Effect.fail(new MeetingTaskError("Workspace is not ready."));
        entry.workspace = {
          id: bootstrap.workspace.id,
          group_id: bootstrap.workspace.group_id,
        };
        yield* this.#persist();
      }
      const workspace = entry.workspace;
      if (!entry.receipt) {
        entry.receipt = yield* ctx.api.request(
          account,
          "POST",
          route`/v1/comma/groups/${workspace.group_id}/meeting-tasks`,
          meetingTaskReceiptSchema,
          entry.entry
        );
        yield* this.#persist();
      }
      // A resend reuses the saved command and its idempotency identifiers.
      while (
        !closedWithoutAudio(entry) &&
        (entry.receipt.meeting.version < entry.version ||
          (entry.final && entry.receipt.meeting.phase === "saving"))
      ) {
        const version = entry.version;
        let command: MeetingTaskCommand;
        if (entry.final) {
          const { recording, sourcePath, smartSummary, recordingId } = entry.final;
          if (!entry.file) {
            stage = "snapshot";
            entry.file = yield* meetingCommand(this.#ports, "snapshot", {
              lease: current,
              sourcePath,
            });
            yield* this.#persist();
          }
          const file: MeetingLocalFile = entry.file;
          stage = "register";
          yield* meetingCommand(this.#ports, "register", {
            lease: current,
            workspaceId: workspace.id,
            file,
          });
          command = {
            action: "finalize",
            version,
            smart_summary: smartSummary,
            recording: {
              recording_id: recordingId,
              durationMs: recording.durationMs,
              driveFile: recording.driveFile,
            },
            file: {
              localFileRef: file.localFileRef,
              name: file.name,
              mediaType: file.mediaType,
              size: file.size,
            },
          };
        } else {
          command = {
            action: entry.action as "recording" | "paused" | "dismiss" | "discard",
            version,
          };
        }
        stage = "submit";
        entry.receipt = yield* ctx.api.request(
          account,
          "POST",
          route`/v1/comma/groups/${workspace.group_id}/meeting-tasks/${id}`,
          meetingTaskReceiptSchema,
          command
        );
        stage = "confirm";
        yield* this.#persist();
        if (command.action === "finalize")
          yield* Effect.ignore(
            meetingCommand(this.#ports, "markBound", {
              localFileRef: command.file.localFileRef,
            })
          );
      }
      this.#show(entry, "synced");
      this.#watchOutputs(entry);
      return entry.receipt;
    });
    return send.pipe(
      Effect.catch((error: unknown) =>
        Effect.suspend(() => {
          const message = meetingSubmissionError(stage, error);
          const retryable =
            Boolean(entry.final && lease) && canRetryMeetingSubmission(stage, error);
          this.#show(entry, "error", message);
          this.#report(entry, stage, message);
          const failure = new MeetingTaskError(message, retryable);
          if (options.schedule && retryable && lease)
            this.#scheduleRetry(entry, lease, failure);
          return Effect.fail(failure);
        })
      )
    );
  }

  /** Tries the failed finalize again on the retry schedule, while the session it failed in is the current one. */
  #scheduleRetry(entry: Entry, lease: SessionLease, failure: MeetingTaskError): void {
    const id = entry.entry.occurrence_id;
    let first = true;
    const resend = Effect.suspend(() => {
      if (first) {
        first = false;
        return Effect.fail(failure);
      }
      return this.#ask<MeetingTaskReceipt>((reply) => ({
        kind: "resend",
        id,
        lease,
        reply,
      }));
    });
    const fiber = this.#ctx.runner.fork(
      Effect.ignore(
        Effect.retry(resend, {
          ...RETRY,
          while: (error: MeetingTaskError) =>
            error.retryable &&
            !this.#closed &&
            sameLease(lease, this.#ctx.session.lease()),
        })
      ),
      this.#scope
    );
    this.#retries.set(id, fiber as Fiber.Fiber<unknown, unknown>);
  }
}
