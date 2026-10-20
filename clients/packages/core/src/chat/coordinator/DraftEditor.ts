import type {
  ChatCommandReceipt,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedAttachmentIdInput,
  ChatLeasedSetDraftInput,
} from "@comma/chat-contract";
import { Duration, Effect } from "effect";
import { ChatError } from "../api";
import type { ChatEntries } from "./entries/ChatEntries";
import type { ChatEntry } from "./entries/chatEntry";
import type { ChatPublisher } from "./entries/ChatPublisher";
import { resolveIntakeFailureAttachment } from "./intake/intakeOutcomes";

/** How long a prefill waits for the conversation's chat to be ready. */
export const PREFILL_READY_MS = 10_000;

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

  /**
   * Adds `input.draft` to the draft once the conversation's chat is ready (at
   * most 10 s), unless the draft already has it. Fails when the chat cannot
   * load.
   */
  prefill(input: ChatLeasedSetDraftInput): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      const settled = () => {
        const { status } = entry.channel.getSnapshot();
        return status === "ready" || status === "error";
      };
      return Effect.raceFirst(
        Effect.callback<void>((resume) => {
          if (settled()) return resume(Effect.void);
          const release = entry.channel.subscribe(() => {
            if (settled()) resume(Effect.void);
          });
          return Effect.sync(release);
        }),
        Effect.sleep(Duration.millis(PREFILL_READY_MS)).pipe(
          Effect.andThen(Effect.fail(new ChatError("Chat did not become ready.")))
        )
      );
    }).pipe(
      Effect.andThen(
        Effect.suspend(() => {
          const entry = this.#entries.required(input);
          const { draft, status } = entry.channel.getSnapshot();
          if (status !== "ready")
            return Effect.fail(new ChatError("Chat is unavailable."));
          // Keep any text already there; asking again adds nothing.
          if (draft.includes(input.draft))
            return Effect.succeed(this.#publisher.receipt(entry));
          return Effect.sync(() =>
            this.setDraft({
              ...input,
              draft: draft.trim() ? `${draft}\n\n${input.draft}` : input.draft,
            })
          );
        })
      )
    );
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
