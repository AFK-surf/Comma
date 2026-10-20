import type { ChatCommandReceipt, ChatLeasedSendInput } from "@comma/chat-contract";
import { Effect } from "effect";
import { ChatError } from "../../api";
import type { ChatEntries } from "../entries/ChatEntries";
import {
  assertNoAttachmentIntakeFailure,
  assertNotSent,
  drainAttachmentIntake,
  draftHasFailedAttachment,
  isReservedBy,
} from "./sendGates";

/**
 * Commits a reserved send intent: drains the draft's attachment intake when
 * the send depends on the draft, then enqueues the canonical
 * message. The enqueue is the linearization point that frees the draft; `onAccepted` is told of it.
 */
export function commitSend(
  entries: ChatEntries,
  input: ChatLeasedSendInput,
  onAccepted?: () => void
): Effect.Effect<ChatCommandReceipt, Error> {
  return Effect.suspend(() => {
    let entry = entries.required(input);
    assertNotSent(entry, input.sendIntentId);
    const intent = entry.activeSendIntent;
    if (!intent || !isReservedBy(intent, input)) {
      throw new ChatError("This send intent is not reserved by Main.");
    }
    if (intent.committing) {
      throw new ChatError("A send is already in progress for this draft.");
    }
    const intentEntry = entry;
    let transportCommitted = false;
    intent.committing = true;
    return Effect.gen(function* () {
      const ownsDraft = entry.draftOwnerSurfaceId === input.surfaceId;
      // Omission preserves the existing send contract, including its draft
      // epoch and attachment-intake fences even when this surface is not the
      // current owner. Only an explicit false makes the send independent.
      const dependsOnDraft = input.consumeDraft !== false;
      const consumeDraft = ownsDraft && dependsOnDraft;

      if (dependsOnDraft && intent.draftEpoch !== entry.draftEpoch) {
        throw new ChatError(
          "The draft changed after this send was started. Review it, then send again."
        );
      }
      if (dependsOnDraft) {
        assertNoAttachmentIntakeFailure(entry);

        // Drain stable snapshots until no intake remains. An intake that
        // settles while another is awaited can delete itself from the live Map;
        // the post-drain outcome check below is therefore mandatory.
        while (entry.attachmentIntakes.size > 0) {
          const intakes = [...entry.attachmentIntakes.values()];
          for (const intake of intakes) {
            const outcome = yield* drainAttachmentIntake(intake);
            if (outcome.errorCount > 0) {
              throw new ChatError(
                "Some selected files could not be attached. Review the attachments, then send again."
              );
            }
          }
          entry = entries.required(input);
          entry.boundary.assertCurrent();
          assertNoAttachmentIntakeFailure(entry);
        }
      }

      if (
        entry.activeSendIntent !== intent ||
        (dependsOnDraft && intent.draftEpoch !== entry.draftEpoch)
      ) {
        throw new ChatError(
          "The draft changed while attachments were settling. Review it, then send again."
        );
      }
      // Final linearization fence: no terminal outcome or newly claimed
      // intake may appear between the drain and canonical enqueue when this
      // send depends on the draft.
      if (dependsOnDraft) assertNoAttachmentIntakeFailure(entry);
      if (dependsOnDraft && draftHasFailedAttachment(entry)) {
        return yield* new ChatError(
          "An attachment failed to upload. Remove or retry it, then send again."
        );
      }
      if (dependsOnDraft && entry.attachmentIntakes.size > 0) {
        throw new ChatError(
          "The message could not be sent because an attachment is not ready. Review the attachments, then send again."
        );
      }

      const beforeSend = entry.channel.getSnapshot();
      const pendingCount = beforeSend.pending.length;
      const files = input.files?.map((file) => ({
        data: new Blob([file.bytes]),
        name: file.name,
        size: file.size,
      }));
      const consumable =
        input.text.trim().length > 0 ||
        Boolean(files?.length) ||
        (consumeDraft &&
          beforeSend.draftAttachments.some(
            (attachment) =>
              attachment.status === "uploaded" || attachment.status === "uploading"
          ));
      const pending = entry.channel.enqueueSend(input.text, {
        consumeDraft,
        ...(files?.length ? { files } : {}),
        ...(input.clientRequestId ? { clientRequestId: input.clientRequestId } : {}),
        ...(input.skills ? { skills: input.skills } : {}),
        ...(input.replyToMessageId ? { replyToMessageId: input.replyToMessageId } : {}),
      });
      const enqueued = entry.channel.getSnapshot().pending.length > pendingCount;
      if (consumable && !enqueued) {
        throw new ChatError(
          "The message could not be sent because an attachment is not ready. Review the attachments, then send again."
        );
      }
      if (enqueued) {
        // In-flight ids remain fenced independently of the committed replay
        // ledger: releasing draft ownership while transport A is pending must
        // not permit A to replay after many faster successor sends.
        entry.inFlightSendIntents.add(input.sendIntentId);
        transportCommitted = true;
      }
      if (consumeDraft && enqueued) {
        entry.draftEpoch += 1;
        entry.boundary.assertCurrent();
        entry.draftOwnerSurfaceId = undefined;
        entry.runtimeProjection = undefined;
        entries.publisher.publish();
        entry.boundary.assertCurrent();
      }
      // Canonical enqueue and draft consumption are the send-intent
      // linearization point. The transport may remain pending for an
      // unbounded time, but it no longer owns the successor draft: release
      // the exact reservation now so B can compose, pick, and send while A's
      // HTTP request settles. The exact in-flight id still fences replay of A.
      if (enqueued && intentEntry.activeSendIntent === intent) {
        intentEntry.activeSendIntent = undefined;
      }
      if (enqueued) onAccepted?.();
      if (pending) yield* entry.channel.transmit(pending);
      entry.boundary.assertCurrent();
      return entries.publisher.receipt(entry);
    }).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          if (transportCommitted) {
            intentEntry.inFlightSendIntents.delete(input.sendIntentId);
            // An exact sendIntentId is idempotent for this Main-owned ChatEntry's
            // full lifetime. There is no protocol-proven replay horizon, so an
            // arbitrary bounded history would make an old completed send
            // admissible again after enough successors.
            intentEntry.committedSendIntents.add(input.sendIntentId);
          }
          if (intentEntry.activeSendIntent === intent) {
            intentEntry.activeSendIntent = undefined;
          }
        })
      )
    );
  });
}
