import type {
  ChatCommandReceipt,
  ChatLeasedAcknowledgeIntakeFailuresInput,
  ChatLeasedTarget,
} from "@comma/chat-contract";
import { claimDraftOwner, requireDraftOwner } from "../DraftEditor";
import type { ChatEntries } from "../entries/ChatEntries";
import type { ChatPublisher } from "../entries/ChatPublisher";
import { StaleChatSessionError } from "../entries/sessionBoundary";
import type {
  ChatAttachmentIntakeClaim,
  ChatAttachmentIntakeOutcome,
  ChatAttachmentIntakeTarget,
} from "../hostContract";
import type { ChatEntryAttachmentIntake } from "./intakeOutcomes";

/** Native attachment intakes: the files a surface picks or receives for its draft. */
export class AttachmentIntake {
  readonly #entries: ChatEntries;
  readonly #publisher: ChatPublisher;
  #attachmentIntakeSequence = 0;

  constructor(entries: ChatEntries) {
    this.#entries = entries;
    this.#publisher = entries.publisher;
  }

  /** Resolve only a live conversation retained by this native window. */
  incomingTarget(
    surfaceId: string
  ): (ChatLeasedTarget & { surfaceId: string; title: string }) | undefined {
    const candidates = [...this.#entries.values()].filter(
      (entry) =>
        entry.boundary.isCurrent() &&
        entry.subscribers.has(`${surfaceId}:${entry.groupId}/${entry.conversationId}`)
    );
    if (candidates.length !== 1) return undefined;
    const entry = candidates[0]!;
    const subscriberId = `${surfaceId}:${entry.groupId}/${entry.conversationId}`;
    return {
      workspaceId: entry.workspaceId,
      groupId: entry.groupId,
      conversationId: entry.conversationId,
      subscriberId,
      leaseId: entry.subscribers.get(subscriberId)!,
      surfaceId,
      title: entry.channel.getSnapshot().conversation?.title || "Comma",
    };
  }

  /**
   * The renderer's confirmation that a failed intake's outcome has been
   * delivered as failure rows. This exact-id ack is diagnostic/delivery
   * state only: Main keeps owning the send gate until an exact projected row
   * is removed or retried.
   */
  acknowledgeFailures(
    input: ChatLeasedAcknowledgeIntakeFailuresInput
  ): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    const failure = entry.attachmentIntakeFailures.get(input.intakeId);
    if (!failure) {
      // Delivery acknowledgement is idempotent. A stale ack for a resolved
      // intake cannot affect any newer terminal outcome.
      return this.#publisher.receipt(entry);
    }
    if (
      failure.surfaceId !== input.surfaceId ||
      failure.subscriberId !== input.subscriberId ||
      failure.leaseId !== input.leaseId
    ) {
      throw new Error("Attachment intake acknowledgement owner mismatch.");
    }
    failure.acknowledged = true;
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  claim(input: ChatAttachmentIntakeTarget): ChatAttachmentIntakeClaim {
    const entry = this.#entries.required(input);
    if (entry.activeSendIntent) {
      throw new Error(
        "A send is already in progress; select files for the successor draft after it settles."
      );
    }
    const previousDraftOwner = entry.draftOwnerSurfaceId;
    claimDraftOwner(entry, input.surfaceId);
    entry.boundary.assertCurrent();

    // Selection is part of composing this draft: while the intake is open,
    // send() must either wait for it to settle or fail retryably — a message
    // must never silently drop files the user selected for it, and a late
    // completion must never leak attachments into a successor draft.
    let settledOutcome: ChatAttachmentIntakeOutcome | undefined;
    let resolveSettled!: (outcome: ChatAttachmentIntakeOutcome) => void;
    const settled = new Promise<ChatAttachmentIntakeOutcome>((resolve) => {
      resolveSettled = resolve;
    });
    // Every claim gets a unique id: no later claim — from another surface
    // or a second call on the SAME surface — can displace this one's fence
    // while its registration is still in flight. Renderer-side single-flight
    // is a UX convenience, never the boundary; a send drains every live
    // intake on the entry.
    const intakeId = `intake-${++this.#attachmentIntakeSequence}`;
    const intake: ChatEntryAttachmentIntake = { dialogOpen: true, settled };
    entry.attachmentIntakes.set(intakeId, intake);
    // Publish the open dialog before awaiting it. Renderer gates its picker
    // control on this, so the signal has to lead the reply, not trail it.
    this.#entries.touch(entry);
    const settle = (outcome: ChatAttachmentIntakeOutcome) => {
      if (settledOutcome) return;
      settledOutcome = outcome;
      intake.dialogOpen = false;
      if (entry.attachmentIntakes.get(intakeId) === intake) {
        entry.attachmentIntakes.delete(intakeId);
      }
      // The open signal must clear on every terminal path, not only the
      // failing one: a clean cancel that never published would leave the
      // control gated on a dialog that is already gone.
      this.#entries.touch(entry);
      if (outcome.errorCount > 0) {
        // The terminal failure outlives the call stack: it stays on the
        // entry and projection — blocking send — until the user explicitly
        // removes/retries every failed selection. An ack or lost IPC reply
        // never transfers this authority into Renderer-only memory.
        entry.attachmentIntakeFailures.set(intakeId, {
          acknowledged: false,
          leaseId: input.leaseId,
          outcome,
          resolvedErrorIndexes: new Set(),
          subscriberId: input.subscriberId,
          surfaceId: input.surfaceId,
        });
        this.#entries.touch(entry);
      }
      resolveSettled(outcome);
    };

    let active = true;
    return {
      intakeId,
      assertCurrent: () => {
        if (!active) {
          throw new Error("The Chat attachment intake claim is no longer active.");
        }
        const current = this.#entries.required(input);
        if (current !== entry) throw new StaleChatSessionError();
        requireDraftOwner(entry, input.surfaceId);
        entry.boundary.assertCurrent();
      },
      markDialogClosed: () => {
        intake.dialogOpen = false;
        this.#entries.touch(entry);
      },
      settle,
      releaseIfUnused: () => {
        if (!active) return;
        active = false;
        // A claim that ends without an explicit outcome settles clean so a
        // waiting send never hangs; providers report real outcomes first.
        settle({ cancelled: true, errorCount: 0 });

        // A cancel/failure must not strand ownership created solely to open
        // the picker. Preserve a pre-existing same-surface owner, any owner
        // takeover, and every claim that already produced draft content.
        if (
          previousDraftOwner !== undefined ||
          this.#entries.get(entry.key) !== entry ||
          entry.draftOwnerSurfaceId !== input.surfaceId
        ) {
          return;
        }
        const state = entry.channel.getSnapshot();
        if (state.draft || state.draftAttachments.length > 0) return;
        entry.draftOwnerSurfaceId = undefined;
        entry.runtimeProjection = undefined;
        this.#publisher.publish(entry.key);
      },
    };
  }
}
