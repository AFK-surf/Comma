import { basename } from "node:path";
import type {
  AudioCaptureRecording,
  SynchronicityMutationResult,
} from "@comma/native-bridge";
import type { CommaApiClient, SalixMessage } from "@comma/app/api";
import type { MainSessionBoundApi } from "../session/main-session-transport";

export const meetingOutputExtensions = [
  "transcript.txt",
  "transcript.json",
  "summary.md",
] as const;
export type MeetingOutputExtension = (typeof meetingOutputExtensions)[number];
export interface MeetingOutputJob {
  id: string;
  account: string;
  groupId: string;
  taskId: string;
  recording: AudioCaptureRecording;
  completed: MeetingOutputExtension[];
}
interface Dependencies {
  account(): string | undefined;
  runOwned<T>(handler: () => Promise<T>): Promise<T>;
  bindSession(): MainSessionBoundApi;
  write(input: {
    space: string;
    path: string;
    content: string;
  }): Promise<SynchronicityMutationResult>;
  checkpoint(job: MeetingOutputJob): Promise<void>;
  publish(job: MeetingOutputJob, outcome: "done" | "error", error?: unknown): void;
}

/** Two active Task SSE streams per install; at most 32 durable jobs in MeetingTaskService.
 * Reuses the server's 30s stream window. No per-file polling or group fan-out.
 * A failed archive waits for explicit retry or the next admitted session.
 */
export class MeetingOutputArchive {
  #pending = new Map<string, MeetingOutputJob>();
  #active = new Map<string, AbortController>();
  #accounts = new Map<string, string>();
  #closed = false;
  constructor(private readonly deps: Dependencies) {}
  watch(job: MeetingOutputJob) {
    if (this.#closed || job.completed.length === 3 || this.#active.has(job.id)) return;
    this.#pending.set(job.id, job);
    this.#pump();
  }
  reconcileAccount() {
    for (const [id, job] of this.#pending)
      if (job.account !== this.deps.account()) this.#pending.delete(id);
    // Every stream callback also passes the Main credential fence.
    for (const [id, controller] of this.#active)
      if (this.#closed || this.#accounts.get(id) !== this.deps.account())
        controller.abort();
  }
  close() {
    this.#closed = true;
    this.#pending.clear();
    this.reconcileAccount();
  }
  #pump() {
    if (this.#closed) return;
    for (const [id, job] of this.#pending) {
      if (this.#active.size >= 2) break;
      this.#pending.delete(id);
      if (job.account !== this.deps.account()) continue;
      const controller = new AbortController();
      this.#active.set(id, controller);
      this.#accounts.set(id, job.account);
      void this.deps
        .runOwned(() => this.#run(job, controller))
        .then(
          () => {
            if (job.completed.length === 3 && job.account === this.deps.account())
              this.deps.publish(job, "done");
          },
          (error) => {
            if (
              !this.#closed &&
              job.account === this.deps.account() &&
              !controller.signal.aborted
            )
              this.deps.publish(job, "error", error);
          }
        )
        .finally(() => {
          this.#active.delete(id);
          this.#accounts.delete(id);
          this.#pump();
        });
    }
  }
  async #run(job: MeetingOutputJob, controller: AbortController) {
    const { api, assertCurrent } = this.deps.bindSession();
    const signal = AbortSignal.any([
      controller.signal,
      AbortSignal.timeout(30 * 60_000),
    ]);
    let dirty = false;
    let drain: Promise<void> | undefined;
    let failure: unknown;
    const consume = () => {
      if (failure) return;
      dirty = true;
      if (drain) return;
      drain = (async () => {
        while (dirty && !signal.aborted) {
          dirty = false;
          const snapshot = await api.getConversation(job.groupId, job.taskId);
          assertCurrent();
          signal.throwIfAborted();
          await archiveMeetingOutputFiles(
            api,
            job,
            snapshot?.messages ?? [],
            async (extension, bytes) => {
              assertCurrent();
              signal.throwIfAborted();
              const result = await this.deps.write({
                space: job.recording.driveFile.space,
                path: job.recording.driveFile.path.replace(
                  /\.(m4a|wav)$/i,
                  `.${extension}`
                ),
                content: Buffer.from(bytes).toString("base64"),
              });
              if (result.status !== "done")
                throw new Error("Drive did not accept the meeting output.");
              assertCurrent();
              job.completed.push(extension);
              await this.deps.checkpoint(job);
            },
            signal
          );
          if (job.completed.length === 3) {
            controller.abort();
            return;
          }
          if (
            snapshot &&
            [
              "completed",
              "cancelled",
              "failed",
              "archived",
              "ready_for_review",
            ].includes(snapshot.status ?? "")
          )
            throw new Error(
              "Meeting outputs are incomplete. Continue the original Task, then retry archiving."
            );
        }
      })()
        .catch((error) => {
          failure = error;
        })
        .finally(() => {
          drain = undefined;
        });
    };
    try {
      while (!signal.aborted && job.completed.length < 3) {
        if (failure) break;
        consume();
        await api
          .streamConversationListEvents(job.groupId, {
            conversationId: job.taskId,
            signal,
            waitMs: 30_000,
            onEvent: () => {
              assertCurrent();
              consume();
            },
          })
          .catch((error) => {
            if (job.completed.length !== 3) throw error;
          });
        await drain;
      }
    } catch (error) {
      await drain;
      // A stream disconnect cannot undo writes that completed while it closed.
      if (job.completed.length !== 3 || failure) throw error;
    } finally {
      // Do not release a job slot while its admitted download/write is still running.
      await drain;
    }
    if (failure) throw failure;
    if (!controller.signal.aborted && job.completed.length !== 3)
      throw new Error("Meeting processing is still pending. Retry archiving later.");
  }
}

/** Only exact, agent-attached expected filenames enter the recorded audio directory.
 * Attachment bytes come from the canonical Task download API, never model-authored paths.
 */
export async function archiveMeetingOutputFiles(
  api: Pick<CommaApiClient, "fetchConversationAttachment">,
  job: MeetingOutputJob,
  messages: SalixMessage[],
  write: (extension: MeetingOutputExtension, bytes: ArrayBuffer) => Promise<void>,
  signal?: AbortSignal
) {
  const stem = basename(job.recording.file.name).replace(/\.(m4a|wav)$/i, "");
  for (const message of messages) {
    if (message.actor_type !== "agent") continue;
    for (const [index, block] of message.content.entries()) {
      if (block.type !== "file") continue;
      const name =
        typeof block.file_name === "string"
          ? block.file_name
          : typeof block.path === "string"
            ? basename(block.path)
            : "";
      const extension = meetingOutputExtensions.find(
        (ext) => name === `${stem}.${ext}`
      );
      if (!extension || job.completed.includes(extension)) continue;
      const blob = await api.fetchConversationAttachment(
        job.groupId,
        job.taskId,
        message.message_id,
        index,
        {
          signal: signal
            ? AbortSignal.any([signal, AbortSignal.timeout(30_000)])
            : AbortSignal.timeout(30_000),
        }
      );
      if (blob.size > 10_000_000)
        throw new Error("Meeting output exceeds the supported file size.");
      await write(extension, await blob.arrayBuffer());
    }
  }
}
