// A summarized meeting's outputs (its transcript as text and JSON, and its summary), saved next to its recording in
// Drive once the agent attached them to the meeting's Task. Only exact, agent-attached expected filenames are saved,
// and their bytes come from the Task's own download, never from a path the model wrote. The summary's heading names
// the Task, unless the person renamed it.
//
// One job: read the Task, save what is new (each save checkpointed in the journal), and wait for the Task to change
// (one Task-list stream the server keeps open up to 30 s) before reading it again; it ends once all three are saved,
// fails when the Task settled without them, and gives up after 30 minutes. The lane (tasks.ts) runs two jobs at a time.
import { CoreError, fromUtf8 } from "@comma/core-kernel";
import { Cause, Duration, Effect, Exit } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import type { Ctx } from "../ctx.ts";
import type { MeetingPorts, MeetingRecording } from "../host.ts";
import { base64 } from "../record.ts";
import { readEvents } from "../sse.ts";
import { meetingCommand } from "./ports.ts";

export const meetingOutputExtensions = [
  "transcript.txt",
  "transcript.json",
  "summary.md",
] as const;
export type MeetingOutputExtension = (typeof meetingOutputExtensions)[number];

export interface MeetingOutputJob {
  id: string;
  account: string;
  workspaceId: string;
  groupId: string;
  taskId: string;
  /** The title the Task was created with. */
  title: string;
  recording: MeetingRecording;
  completed: MeetingOutputExtension[];
}

const conversationSchema = z
  .object({
    status: z.string().optional(),
    title: z.string().optional(),
    messages: z
      .array(
        z
          .object({
            message_id: z.string(),
            actor_type: z.string(),
            content: z.array(z.unknown()),
          })
          .loose()
      )
      .optional(),
  })
  .loose();
type Conversation = z.infer<typeof conversationSchema>;

const fileBlockSchema = z
  .object({
    type: z.literal("file"),
    file_name: z.string().optional(),
    path: z.string().optional(),
  })
  .loose();

const SETTLED = new Set([
  "completed",
  "cancelled",
  "failed",
  "archived",
  "ready_for_review",
]);
const STREAM_WAIT_MS = 30_000;
const JOB_MS = 30 * 60_000;
const ATTACHMENT_MS = 30_000;
const MAX_BYTES = 10_000_000;

const basename = (path: string) => path.slice(path.lastIndexOf("/") + 1);
/** An event came: the Task changed. */
const CHANGED = new CoreError("changed", "the Task changed");

/**
 * How a job ended: `settled` when the Task ended without attaching its outputs, `pending` when it did not attach them
 * in time, `error` when reading or saving them failed.
 */
export type MeetingOutputEnd = "done" | "settled" | "pending" | "error";

export function meetingOutputEnd(exit: Exit.Exit<void, unknown>): MeetingOutputEnd {
  if (Exit.isSuccess(exit)) return "done";
  const error = Cause.squash(exit.cause);
  if (!(error instanceof CoreError)) return "error";
  return error.code === "outputs_incomplete"
    ? "settled"
    : error.code === "outputs_pending"
      ? "pending"
      : "error";
}

/** Saves `job`'s outputs, `checkpoint` after each; done once all three are saved. */
export function archiveMeetingOutputs(
  ctx: Ctx,
  ports: MeetingPorts,
  job: MeetingOutputJob,
  checkpoint: () => Effect.Effect<void, unknown>
): Effect.Effect<void, unknown> {
  return Effect.gen(function* () {
    const account = yield* ctx.session.account();
    if (`${account.lease.audience}:${account.userId}` !== job.account)
      return yield* Effect.fail(new CoreError("signed_out", "Another account."));
    const events = `${route`/v1/comma/groups/${job.groupId}/conversations/events`}?wait=${STREAM_WAIT_MS}&conversation_id=${encodeURIComponent(job.taskId)}`;
    for (;;) {
      const snapshot = yield* ctx.api.request(
        account,
        "GET",
        route`/v1/comma/groups/${job.groupId}/conversations/${job.taskId}`,
        conversationSchema
      );
      yield* saveOutputs(ctx, ports, account, job, snapshot, checkpoint);
      if (job.completed.length === 3) return;
      if (SETTLED.has(snapshot.status ?? ""))
        return yield* Effect.fail(
          new CoreError(
            "outputs_incomplete",
            "Meeting outputs are incomplete. Continue the original Task, then retry archiving."
          )
        );
      // Wait for the Task to change (an event), or the server's wait to end: then read it again.
      yield* Effect.scoped(
        ctx.api
          .stream(account, events)
          .pipe(Effect.flatMap((body) => readEvents(body, () => Effect.fail(CHANGED))))
      ).pipe(
        Effect.catchIf(
          (error) => error === CHANGED,
          () => Effect.void
        )
      );
    }
  }).pipe(
    Effect.timeoutOrElse({
      duration: Duration.millis(JOB_MS),
      orElse: () =>
        Effect.fail(
          new CoreError(
            "outputs_pending",
            "Meeting processing is still pending. Retry archiving later."
          )
        ),
    })
  );
}

/** Saves each expected output the agent attached that is not saved yet, checkpointing after each. */
function saveOutputs(
  ctx: Ctx,
  ports: MeetingPorts,
  account: Account,
  job: MeetingOutputJob,
  task: Conversation,
  checkpoint: () => Effect.Effect<void, unknown>
): Effect.Effect<void, unknown> {
  return Effect.gen(function* () {
    const stem = basename(job.recording.file.name).replace(/\.(m4a|wav)$/i, "");
    for (const message of task.messages ?? []) {
      if (message.actor_type !== "agent") continue;
      for (const [index, raw] of message.content.entries()) {
        const block = fileBlockSchema.safeParse(raw);
        if (!block.success) continue;
        const name =
          block.data.file_name ?? (block.data.path ? basename(block.data.path) : "");
        const extension = meetingOutputExtensions.find(
          (ext) => name === `${stem}.${ext}`
        );
        if (!extension || job.completed.includes(extension)) continue;
        const response = yield* ctx.api.raw(
          account,
          "GET",
          route`/v1/comma/groups/${job.groupId}/conversations/${job.taskId}/messages/${message.message_id}/attachments/${String(index)}`,
          { timeoutMs: ATTACHMENT_MS }
        );
        if (response.body.length > MAX_BYTES)
          return yield* Effect.fail(
            new CoreError(
              "too_large",
              "Meeting output exceeds the supported file size."
            )
          );
        // Before the summary's checkpoint: when this try ends sooner, the next one names the Task. A title the
        // server refused (a network failure, the Task archived since the read) never keeps the summary from Drive.
        if (extension === "summary.md")
          yield* nameTask(ctx, account, job, task, response.body);
        yield* meetingCommand(ports, "write", {
          lease: account.lease,
          space: job.recording.driveFile.space,
          path: job.recording.driveFile.path.replace(/\.(m4a|wav)$/i, `.${extension}`),
          content: base64(response.body),
        });
        if (account.closed)
          return yield* Effect.fail(new CoreError("signed_out", "Another account."));
        job.completed.push(extension);
        yield* checkpoint();
      }
    }
  });
}

/**
 * The summary's first level-1 heading becomes the Task's title, while the Task keeps the title it was created with (a
 * title the person gave it stays) and is not archived (an archived Task takes no changes).
 */
function nameTask(
  ctx: Ctx,
  account: Account,
  job: MeetingOutputJob,
  task: Conversation,
  summary: Uint8Array
): Effect.Effect<void, unknown> {
  const title = /^# +(.+)$/m.exec(fromUtf8(summary))?.[1]?.trim();
  if (!title || task.title !== job.title || task.status === "archived")
    return Effect.void;
  return Effect.ignore(
    ctx.api.request(
      account,
      "PATCH",
      route`/v1/comma/groups/${job.groupId}/conversations/${job.taskId}`,
      z.unknown(),
      { title }
    )
  );
}
