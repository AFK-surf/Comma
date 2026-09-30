import type {
  ChatCommandReceipt,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedAttachmentIdInput,
  ChatLeasedSetDraftInput,
} from "@comma/chat-contract";
import type { ChatEntries } from "./entries/ChatEntries";
import type { ChatEntry } from "./entries/chatEntry";
import type { ChatPublisher } from "./entries/ChatPublisher";
import { resolveIntakeFailureAttachment } from "./intake/intakeOutcomes";

/**
 * Edits to an entry's shared draft. Only the surface owning the draft edits
 * it, and each intent change moves the draft epoch that fences a send.
 */
export class DraftEditor {
  readonly #entries: ChatEntries;
  readonly #publisher: ChatPublisher;

  constructor(entries: ChatEntries) {
    this.#entries = entries;
    this.#publisher = entries.publisher;
  }

  setDraft(input: ChatLeasedSetDraftInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    claimDraftOwner(entry, input.surfaceId);
    // A text edit is a user intent change: any send still draining an
    // attachment intake must re-admit against this newer draft, not consume it.
    entry.draftEpoch += 1;
    entry.channel.setDraft(input.draft);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  // Attaching is additive composition by the draft-owning surface and does
  // not move the epoch: an admitted send includes files the owner added while
  // it settled (closed-dialog intake, late admissions), while cross-surface
  // consumption is already blocked by draft ownership. Text edits, removals,
  // and consumption are the intent changes that fence a send.
  attach(input: ChatLeasedAttachInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    claimDraftOwner(entry, input.surfaceId);
    entry.channel.attachFiles([
      {
        data: new Blob([input.bytes]),
        name: input.name,
        size: input.size,
      },
    ]);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  attachLocalFiles(input: ChatLeasedAttachLocalFilesInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    claimDraftOwner(entry, input.surfaceId);
    entry.channel.attachLocalFiles(input.files);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  removeAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    const resolved = this.#resolveIntakeFailure(entry, input.attachmentId);
    if (resolved) return resolved;
    requireDraftOwner(entry, input.surfaceId);
    entry.draftEpoch += 1;
    entry.channel.removeAttachment(input.attachmentId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  retryAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    const resolved = this.#resolveIntakeFailure(entry, input.attachmentId);
    if (resolved) return resolved;
    requireDraftOwner(entry, input.surfaceId);
    entry.channel.retryAttachment(input.attachmentId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  /** Removing or retrying an intake failure row is an intent change as well. */
  #resolveIntakeFailure(entry: ChatEntry, attachmentId: string) {
    if (!resolveIntakeFailureAttachment(entry.attachmentIntakeFailures, attachmentId)) {
      return undefined;
    }
    entry.draftEpoch += 1;
    this.#entries.touch(entry);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }
}

export function claimDraftOwner(entry: ChatEntry, surfaceId: string) {
  const currentOwner = entry.draftOwnerSurfaceId;
  if (currentOwner === surfaceId) return;
  if (currentOwner) {
    const state = entry.channel.getSnapshot();
    if (state.draft || state.draftAttachments.length > 0) {
      throw new Error("Chat draft belongs to another surface.");
    }
  }
  entry.draftOwnerSurfaceId = surfaceId;
  entry.runtimeProjection = undefined;
}

export function requireDraftOwner(entry: ChatEntry, surfaceId: string) {
  if (entry.draftOwnerSurfaceId !== surfaceId) {
    throw new Error("Chat draft attachments belong to another surface.");
  }
}
