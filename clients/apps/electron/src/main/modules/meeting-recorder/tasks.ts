import {
  canRetryMeetingSubmission,
  meetingSubmissionError,
  type MeetingSubmissionStage,
} from "./submission-error";
import { MeetingOutputArchive, meetingOutputExtensions } from "./outputs";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import {
  localFileSnapshotSchema,
  audioCaptureRecordingSchema,
  type AudioCaptureRecording,
  type MeetingPresenceMeeting,
} from "@comma/native-bridge";
import {
  meetingTaskReceiptSchema,
  type MeetingTaskCommand,
  type MeetingTaskReceipt,
} from "@comma/app/api";
import type { MainSessionBoundApi } from "../session/main-session-transport";
import type {
  LocalFileSnapshotStore,
  LocalFileRouteRegistrationService,
} from "../local-files";

const entrySchema = z.object({
  account: z.string(),
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
  file: localFileSnapshotSchema.optional(),
  outputs: z.array(z.enum(meetingOutputExtensions)).max(3).default([]),
  version: z.number().int().nonnegative(),
  action: z.enum(["recording", "paused", "dismiss", "discard", "finalize"]).optional(),
  final: z
    .object({
      recording: audioCaptureRecordingSchema,
      sourcePath: z.string(),
      recordingId: z.string(),
      smartSummary: z.boolean(),
    })
    .optional(),
});
type Entry = z.infer<typeof entrySchema>;
export type MeetingTaskState = {
  task?: { groupId: string; taskId: string };
  status: "pending" | "synced" | "error";
  error?: string;
  archive?: "done" | "error";
  recording?: AudioCaptureRecording;
};
interface Dependencies {
  filePath: string;
  reportFailure?(details: {
    occurrenceId: string;
    version: number;
    stage: MeetingSubmissionStage;
    message: string;
  }): void;
  writeOutput?: ConstructorParameters<typeof MeetingOutputArchive>[0]["write"];
  account(): string | undefined;
  runOwned<T>(handler: () => Promise<T>): Promise<T>;
  bindSession(): MainSessionBoundApi;
  ownerUserId(): string;
  files: Pick<LocalFileSnapshotStore, "snapshot" | "markBound">;
  registrar: Pick<LocalFileRouteRegistrationService, "register">;
  publish(key: string, state: MeetingTaskState): void;
  resolveRecovery(name: string): Promise<"resume" | "new">;
}

// At most 32 retained meetings. Each failed finalize has two delayed attempts.
// Retries share the existing serial command lane. Detection does not start timers.
const SUBMISSION_RETRY_DELAYS_MS = [5_000, 15_000] as const;

// The server archives a dismissed meeting and cancels a discarded one. It rejects every newer command.
function closedWithoutAudio(entry: Entry) {
  const phase = entry.receipt?.meeting.phase;
  return !entry.final && (phase === "dismissed" || phase === "discarded");
}

/** One bounded durable command lane for entry, submission, and recovery. */
export class MeetingTaskService {
  #entries: Entry[] = [];
  #current = new Map<string, string>();
  #writes: Promise<void> = Promise.resolve();
  #network: Promise<unknown> = Promise.resolve();
  #inflight = new Map<string, Promise<MeetingTaskReceipt>>();
  #entering = new Map<string, Promise<void>>();
  #retryTimers = new Map<string, ReturnType<typeof setTimeout>>();
  #retryCounts = new Map<string, number>();
  #closed = false;
  #loadError: string | undefined;
  #outputs: MeetingOutputArchive | undefined;
  private constructor(private readonly deps: Dependencies) {
    if (deps.writeOutput)
      this.#outputs = new MeetingOutputArchive({
        account: deps.account,
        runOwned: deps.runOwned,
        bindSession: deps.bindSession,
        write: deps.writeOutput,
        checkpoint: async (job) => {
          const entry = this.#entries.find((e) => e.entry.occurrence_id === job.id);
          if (entry) {
            entry.outputs = [...job.completed];
            await this.#persist();
          }
        },
        publish: (job, archive) => {
          if (!this.#closed && job.account === deps.account()) {
            const entry = this.#entries.find((e) => e.entry.occurrence_id === job.id);
            if (entry)
              deps.publish(entry.key, {
                status: "synced",
                task: { groupId: job.groupId, taskId: job.taskId },
                archive,
                recording: job.recording,
              });
          }
        },
      });
  }
  #watchOutputs(entry: Entry) {
    if (
      !entry.final?.smartSummary ||
      !entry.receipt ||
      entry.receipt.meeting.phase !== "processing"
    )
      return;
    this.#outputs?.watch({
      id: entry.entry.occurrence_id,
      account: entry.account,
      groupId: entry.receipt.group_id,
      taskId: entry.receipt.task_id,
      recording: entry.final.recording,
      completed: [...entry.outputs],
    });
  }
  static async open(deps: Dependencies) {
    const service = new MeetingTaskService(deps);
    try {
      const text = await readFile(deps.filePath, "utf8");
      if (text.length > 512_000)
        throw new Error("Meeting sync journal exceeds its limit.");
      service.#entries = z.array(entrySchema).max(32).parse(JSON.parse(text));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT")
        service.#loadError =
          "Saved meeting sync data could not be read. Audio recording remains available; restore the meeting journal before syncing Tasks.";
    }
    return service;
  }

  enter(meeting: MeetingPresenceMeeting): Promise<void> {
    return this.#enterOnce(meeting);
  }

  #enterOnce(meeting: MeetingPresenceMeeting, replaced?: Entry): Promise<void> {
    if (this.#loadError) return Promise.reject(new Error(this.#loadError));
    if (this.#closed) return Promise.reject(new Error("Meeting sync is closed."));
    const account = this.deps.account();
    if (!account) return Promise.reject(new Error("Sign in to sync this meeting."));
    const key = `${account}:${meeting.key}`;
    if (!replaced && this.#current.has(key)) return Promise.resolve();
    const pending = this.#entering.get(key);
    if (pending) return pending;
    const result = this.#enter(meeting, account, key, replaced).finally(() =>
      this.#entering.delete(key)
    );
    this.#entering.set(key, result);
    return result;
  }

  async #enter(
    meeting: MeetingPresenceMeeting,
    account: string,
    key: string,
    replaced?: Entry
  ) {
    // A restarted detector cannot prove continuity. Ask before reusing its old Task.
    // A replaced occurrence keeps its live presence key, which proves continuity.
    const prior = replaced
      ? undefined
      : this.#entries.find(
          (e) =>
            e.account === account &&
            e.app === meeting.name &&
            !e.final &&
            !closedWithoutAudio(e) &&
            !(["dismiss", "discard"] as const).includes(
              e.action as "dismiss" | "discard"
            ) &&
            ![...this.#current.values()].includes(e.entry.occurrence_id)
        );
    let entry: Entry | undefined;
    if (prior) {
      if ((await this.deps.resolveRecovery(prior.entry.name)) === "resume")
        entry = prior;
      else if (!prior.action) {
        // The user declined the old unrecorded occurrence; preserve its archive command.
        prior.action = "dismiss";
        prior.version++;
        await this.#persist();
        void this.#sync(prior).catch(() => undefined);
      }
    }
    if (this.deps.account() !== account || this.#closed)
      throw new Error("The meeting account changed.");
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
        throw new Error(
          "32 meetings are waiting to sync. Resolve them before creating another meeting Task."
        );
      const now = new Date();
      entry = {
        account,
        key: meeting.key,
        app: meeting.name,
        version: 0,
        outputs: [],
        entry: {
          occurrence_id: randomUUID(),
          name: meeting.name,
          // The same meeting keeps its start time and the archive date of its recording.
          started_at: replaced?.entry.started_at ?? now.getTime(),
          archive_date:
            replaced?.entry.archive_date ??
            `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`,
        },
      };
      this.#entries.push(entry);
    }
    entry.key = meeting.key;
    await this.#persist();
    this.#current.set(key, entry.entry.occurrence_id);
    // The closed occurrence leaves the journal with the next write, now that its key moved.
    if (replaced && closedWithoutAudio(replaced))
      this.#entries = this.#entries.filter((e) => e !== replaced);
    this.#publish(entry, "pending");
    void this.#sync(entry).catch(() => undefined);
  }

  async change(
    meeting: MeetingPresenceMeeting,
    action: "recording" | "paused" | "dismiss" | "discard"
  ) {
    await this.enter(meeting);
    let entry = this.#get(meeting.key);
    if (entry.final) return;
    if (
      entry.action === "dismiss" ||
      entry.action === "discard" ||
      closedWithoutAudio(entry)
    ) {
      // Presence can offer the same meeting again after its occurrence closed.
      if (action === "dismiss" || action === "discard") return;
      await this.#enterOnce(meeting, entry);
      entry = this.#get(meeting.key);
    }
    entry.action = action;
    entry.version++;
    await this.#persist();
    this.#publish(entry, "pending");
    void this.#sync(entry).catch(() => undefined);
  }

  async finalize(
    meetingKey: string,
    recording: AudioCaptureRecording,
    sourcePath: string,
    smartSummary: boolean
  ) {
    const entry = this.#get(meetingKey);
    if (!entry.final) {
      entry.final = { recording, sourcePath, smartSummary, recordingId: randomUUID() };
      entry.action = "finalize";
      entry.version++;
      try {
        await this.#persist();
      } catch (error) {
        const message = meetingSubmissionError("journal", error);
        this.#publish(entry, "error", message);
        this.deps.reportFailure?.({
          occurrenceId: entry.entry.occurrence_id,
          version: entry.version,
          stage: "journal",
          message,
        });
        throw new Error(message, { cause: error });
      }
    }
    this.#publish(entry, "pending");
    return this.#sync(entry);
  }

  archiveTime(meetingKey: string) {
    return this.#get(meetingKey).entry.started_at;
  }

  async retryPending() {
    if (this.#loadError || this.#closed) return;
    this.#outputs?.reconcileAccount();
    for (const entry of this.#entries)
      if (entry.account === this.deps.account()) this.#watchOutputs(entry);
    const pending = this.#entries.filter(
      (entry) =>
        entry.account === this.deps.account() &&
        !closedWithoutAudio(entry) &&
        (!entry.receipt ||
          entry.receipt.meeting.version < entry.version ||
          entry.receipt.meeting.phase === "saving")
    );
    for (const entry of pending) this.#retryCounts.delete(entry.entry.occurrence_id);
    await Promise.allSettled(pending.map((entry) => this.#sync(entry)));
  }
  async close() {
    this.#closed = true;
    for (const timer of this.#retryTimers.values()) clearTimeout(timer);
    this.#retryTimers.clear();
    this.#retryCounts.clear();
    this.#outputs?.close();
    await this.#network;
    await this.#writes;
  }
  #get(key: string) {
    const id = this.#current.get(`${this.deps.account()}:${key}`);
    const entry = this.#entries.find((e) => e.entry.occurrence_id === id);
    if (!entry) throw new Error("This meeting has no saved Task association.");
    return entry;
  }
  #persist() {
    const data = JSON.stringify(this.#entries);
    const write = this.#writes.then(async () => {
      await mkdir(dirname(this.deps.filePath), { recursive: true });
      await writeFile(`${this.deps.filePath}.tmp`, data, { mode: 0o600 });
      await rename(`${this.deps.filePath}.tmp`, this.deps.filePath);
    });
    this.#writes = write.catch(() => undefined);
    return write;
  }
  #publish(entry: Entry, status: MeetingTaskState["status"], error?: string) {
    if (entry.account !== this.deps.account() || this.#closed) return;
    // Only the occurrence that owns the key publishes. A closed occurrence without a key
    // has no view, and its late result must not overwrite a replacement's saved card.
    const owner = this.#current.get(`${entry.account}:${entry.key}`);
    const closed =
      entry.action === "dismiss" ||
      entry.action === "discard" ||
      closedWithoutAudio(entry);
    if (owner ? owner !== entry.entry.occurrence_id : closed) return;
    this.deps.publish(entry.key, {
      status,
      ...(entry.receipt
        ? { task: { groupId: entry.receipt.group_id, taskId: entry.receipt.task_id } }
        : {}),
      ...(error ? { error } : {}),
    });
  }
  #sync(
    entry: Entry,
    expectedBinding?: MainSessionBoundApi
  ): Promise<MeetingTaskReceipt> {
    const id = entry.entry.occurrence_id;
    const existing = this.#inflight.get(id);
    if (existing) return existing;
    const timer = this.#retryTimers.get(id);
    if (timer) clearTimeout(timer);
    this.#retryTimers.delete(id);
    let stage: MeetingSubmissionStage = "prepare";
    let binding: MainSessionBoundApi | undefined;
    const sync = this.#network
      .then(() =>
        this.deps.runOwned(async () => {
          if (this.#closed || entry.account !== this.deps.account())
            throw new Error("The meeting account changed.");
          expectedBinding?.assertCurrent();
          binding = this.deps.bindSession();
          const apiBinding = binding;
          if (!entry.workspace) {
            const bootstrap = await apiBinding.api.bootstrapWorkspace();
            if (bootstrap.status !== "ready")
              throw new Error("Workspace is not ready.");
            entry.workspace = {
              id: bootstrap.workspace.id,
              group_id: bootstrap.workspace.group_id,
            };
            await this.#persist();
          }
          const workspace = entry.workspace;
          if (!entry.receipt) {
            entry.receipt = await apiBinding.api.enterMeetingTask(
              workspace.group_id,
              entry.entry
            );
            await this.#persist();
          }
          // A retry reuses the saved command and its idempotency identifiers.
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
                entry.file = await this.deps.files.snapshot(
                  sourcePath,
                  this.deps.ownerUserId()
                );
                await this.#persist();
              }
              const file = entry.file;
              stage = "register";
              await this.deps.registrar.register(
                workspace.id,
                file,
                apiBinding.assertCurrent
              );
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
            apiBinding.assertCurrent();
            entry.receipt = await apiBinding.api.updateMeetingTask(
              workspace.group_id,
              id,
              command
            );
            stage = "confirm";
            await this.#persist();
            if (command.action === "finalize")
              await this.deps.files
                .markBound(command.file.localFileRef)
                .catch(() => undefined);
          }
          this.#retryCounts.delete(id);
          this.#publish(entry, "synced");
          this.#watchOutputs(entry);
          return entry.receipt;
        })
      )
      .catch((error: unknown) => {
        const message = meetingSubmissionError(stage, error);
        this.#publish(entry, "error", message);
        this.deps.reportFailure?.({
          occurrenceId: id,
          version: entry.version,
          stage,
          message,
        });
        if (entry.final && binding && canRetryMeetingSubmission(stage, error))
          this.#scheduleRetry(entry, binding);
        throw new Error(message, { cause: error });
      })
      .finally(() => this.#inflight.delete(id));
    this.#network = sync.catch(() => undefined);
    this.#inflight.set(id, sync);
    return sync;
  }
  #scheduleRetry(entry: Entry, binding: MainSessionBoundApi) {
    const id = entry.entry.occurrence_id;
    const attempt = this.#retryCounts.get(id) ?? 0;
    const delay = SUBMISSION_RETRY_DELAYS_MS[attempt];
    if (delay === undefined || this.#closed || !binding.isCurrent()) return;
    this.#retryCounts.set(id, attempt + 1);
    const timer = setTimeout(() => {
      this.#retryTimers.delete(id);
      if (this.#closed || entry.account !== this.deps.account() || !binding.isCurrent())
        return;
      this.#publish(entry, "pending");
      void this.#sync(entry, binding).catch(() => undefined);
    }, delay);
    timer.unref();
    this.#retryTimers.set(id, timer);
  }
}
