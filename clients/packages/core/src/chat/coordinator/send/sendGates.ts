import { Duration, Effect } from "effect";
import { ChatError } from "../../api";
import type { ChatEntry, ChatSendIntentReservation } from "../entries/chatEntry";
import type { ChatAttachmentIntakeOutcome } from "../hostContract";
import type { ChatEntryAttachmentIntake } from "../intake/intakeOutcomes";

const ATTACHMENT_INTAKE_DRAIN_TIMEOUT_MS = 20_000;

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
    throw new ChatError("This message was already sent.");
  }
}

export function assertNoAttachmentIntakeFailure(entry: ChatEntry) {
  if (entry.attachmentIntakeFailures.size > 0) {
    throw new ChatError(
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
export function drainAttachmentIntake(
  intake: ChatEntryAttachmentIntake
): Effect.Effect<ChatAttachmentIntakeOutcome, Error> {
  return Effect.suspend(() => {
    if (intake.dialogOpen) {
      return Effect.fail(
        new ChatError(
          "Files are still being selected for this message. Close the file dialog, then send again."
        )
      );
    }
    return Effect.raceFirst(
      Effect.callback<ChatAttachmentIntakeOutcome>((resume) => {
        if (intake.outcome) return resume(Effect.succeed(intake.outcome));
        const wake = () => resume(Effect.succeed(intake.outcome!));
        intake.waiters.add(wake);
        return Effect.sync(() => intake.waiters.delete(wake));
      }),
      Effect.sleep(Duration.millis(ATTACHMENT_INTAKE_DRAIN_TIMEOUT_MS)).pipe(
        Effect.andThen(
          Effect.fail(
            new ChatError(
              "Selected files are still being attached. Try sending again in a moment."
            )
          )
        )
      )
    );
  });
}

/**
 * A draft is send-blocked while any attachment has failed: the send must
 * surface as an explicit, draft-preserving failure, never as a silently
 * skipped enqueue. An attachment still uploading goes with the message,
 * which waits for it.
 */
export function draftHasFailedAttachment(entry: ChatEntry) {
  return entry.channel
    .getSnapshot()
    .draftAttachments.some((attachment) => attachment.status === "failed");
}
