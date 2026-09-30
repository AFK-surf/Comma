import type { ChatEntry, ChatSendIntentReservation } from "../entries/chatEntry";
import type { ChatAttachmentIntakeOutcome } from "../hostContract";
import type { ChatEntryAttachmentIntake } from "../intake/intakeOutcomes";

const ATTACHMENT_INTAKE_DRAIN_TIMEOUT_MS = 20_000;

function delayMs(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}

/** Whether `intent` is the exact reservation `input` names. */
export function isReservedBy(
  intent: ChatSendIntentReservation,
  input: Pick<
    ChatSendIntentReservation,
    "leaseId" | "sendIntentId" | "subscriberId" | "surfaceId"
  >
) {
  return (
    intent.sendIntentId === input.sendIntentId &&
    intent.surfaceId === input.surfaceId &&
    intent.subscriberId === input.subscriberId &&
    intent.leaseId === input.leaseId
  );
}

/** A send intent id is spent once its transport was committed. */
export function assertNotSent(entry: ChatEntry, sendIntentId: string) {
  if (
    entry.inFlightSendIntents.has(sendIntentId) ||
    entry.committedSendIntents.has(sendIntentId)
  ) {
    throw new Error("This message was already sent.");
  }
}

export function assertNoAttachmentIntakeFailure(entry: ChatEntry) {
  if (entry.attachmentIntakeFailures.size > 0) {
    throw new Error(
      "Some selected files could not be attached. Review the attachments, then send again."
    );
  }
}

/**
 * Send admission for an in-flight native attachment intake. A message must
 * carry every file the user selected for it: while the picker dialog is
 * still open the send fails fast and retryably; after the dialog closed,
 * the send waits, bounded, for the intake's typed outcome. Callers must
 * only invoke this when an intake exists so that intake-free sends keep
 * their synchronous enqueue behavior.
 */
export async function drainAttachmentIntake(
  intake: ChatEntryAttachmentIntake
): Promise<ChatAttachmentIntakeOutcome> {
  if (intake.dialogOpen) {
    throw new Error(
      "Files are still being selected for this message. Close the file dialog, then send again."
    );
  }
  const outcome = await Promise.race([
    intake.settled,
    delayMs(ATTACHMENT_INTAKE_DRAIN_TIMEOUT_MS).then(() => undefined),
  ]);
  if (!outcome) {
    throw new Error(
      "Selected files are still being attached. Try sending again in a moment."
    );
  }
  return outcome;
}

/**
 * A draft is send-blocked while any attachment is still uploading or has
 * already failed. Both must route the send through the admission drain: an
 * upload that failed before the click must surface as an explicit, draft-
 * preserving send failure, never as a silently skipped enqueue.
 */
export function draftHasBlockedAttachments(entry: ChatEntry) {
  return entry.channel
    .getSnapshot()
    .draftAttachments.some(
      (attachment) =>
        attachment.status === "uploading" || attachment.status === "failed"
    );
}

/**
 * An accepted send must never be silently skipped by the channel because an
 * upload is still in flight: wait, bounded, until no draft attachment is
 * uploading, and fail retryably if any settled as failed — the channel
 * would otherwise drop the whole enqueue while reporting success.
 */
export async function drainUploadingAttachments(entry: ChatEntry) {
  const deadline = Date.now() + ATTACHMENT_INTAKE_DRAIN_TIMEOUT_MS;
  for (;;) {
    const attachments = entry.channel.getSnapshot().draftAttachments;
    if (attachments.some((attachment) => attachment.status === "failed")) {
      throw new Error(
        "An attachment failed to upload. Remove or retry it, then send again."
      );
    }
    if (!attachments.some((attachment) => attachment.status === "uploading")) {
      return;
    }
    if (Date.now() >= deadline) {
      throw new Error(
        "Attachments are still uploading. Try sending again in a moment."
      );
    }
    await new Promise<void>((resolve) => {
      const unsubscribe = entry.channel.subscribe(() => {
        unsubscribe();
        resolve();
      });
      const timer = setTimeout(() => {
        unsubscribe();
        resolve();
      }, 250);
      timer.unref?.();
    });
  }
}
