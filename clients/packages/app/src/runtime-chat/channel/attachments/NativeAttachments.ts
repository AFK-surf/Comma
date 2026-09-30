import type { DraftAttachment } from "../../../components/chat/model/conversationChannel";

type NativeAttachmentWaiter = {
  attachmentIds: Set<string>;
  resolve(): void;
};

/**
 * The draft attachments Main projects, the ones among them this renderer is
 * removing, and the sends waiting for projected uploads to settle.
 */
export class NativeAttachments {
  #attachments: DraftAttachment[] = [];
  readonly #suppressedIds = new Set<string>();
  readonly #waiters = new Set<NativeAttachmentWaiter>();

  get list() {
    return this.#attachments;
  }

  /** Adopts Main's projection, forgetting removals it no longer projects. */
  adopt(attachments: DraftAttachment[]) {
    this.#attachments = attachments;
    for (const attachmentId of this.#suppressedIds) {
      if (!attachments.some((attachment) => attachment.id === attachmentId)) {
        this.#suppressedIds.delete(attachmentId);
      }
    }
  }

  /** The projected attachments not being removed by this renderer. */
  visible() {
    return this.#attachments.filter(
      (attachment) => !this.#suppressedIds.has(attachment.id)
    );
  }

  suppress(attachmentId: string) {
    this.#suppressedIds.add(attachmentId);
  }

  unsuppress(attachmentId: string) {
    this.#suppressedIds.delete(attachmentId);
  }

  waitForSettled(attachmentIds: Set<string>) {
    if (this.#settled(attachmentIds)) {
      return Promise.resolve();
    }

    return new Promise<void>((resolve) => {
      this.#waiters.add({ attachmentIds, resolve });
    });
  }

  /** Releases every waiter whose attachments the adopted projection settled. */
  settleWaiters() {
    for (const waiter of this.#waiters) {
      if (this.#settled(waiter.attachmentIds)) {
        this.#waiters.delete(waiter);
        waiter.resolve();
      }
    }
  }

  /** Forgets local removals and releases every waiter. */
  abandon() {
    this.#suppressedIds.clear();
    for (const waiter of this.#waiters) {
      waiter.resolve();
    }
    this.#waiters.clear();
  }

  /** Forgets everything, the projection included. */
  clear() {
    this.abandon();
    this.#attachments = [];
  }

  #settled(attachmentIds: Set<string>) {
    return [...attachmentIds].every((attachmentId) => {
      const attachment = this.#attachments.find(
        (candidate) => candidate.id === attachmentId
      );
      return !attachment || attachment.status !== "uploading";
    });
  }
}
