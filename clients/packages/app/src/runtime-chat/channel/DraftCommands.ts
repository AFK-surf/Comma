import type { ChannelLease, SessionBoundChatLease } from "./ChannelLease";

type DraftEpochReceipt = { draftEpoch?: number | undefined };

/**
 * The renderer's one command sequence for draft mutations and send
 * reservations, and its shadow of the Main-owned draft epoch.
 */
export class DraftCommands {
  readonly #lease: ChannelLease;
  #draftEpoch: number | undefined;
  #draftMutationTail: Promise<void> = Promise.resolve();

  constructor(lease: ChannelLease) {
    this.#lease = lease;
  }

  /** A new lifecycle starts an empty sequence before any epoch is observed. */
  restart() {
    this.#draftEpoch = undefined;
    this.#draftMutationTail = Promise.resolve();
  }

  /**
   * Tracks the Main-owned draft epoch. Receipts from this renderer's own
   * draft mutations arrive in call order and projections carry foreign
   * surfaces' changes. This shadow is observational only: send never reads
   * or transmits it; Main's beginSendIntent owns the authoritative epoch.
   */
  observeDraftEpoch(receipt: DraftEpochReceipt) {
    if (typeof receipt.draftEpoch !== "number") return;
    this.#draftEpoch =
      this.#draftEpoch === undefined
        ? receipt.draftEpoch
        : Math.max(this.#draftEpoch, receipt.draftEpoch);
  }

  /**
   * Serializes draft mutations and beginSendIntent in one Renderer command
   * sequence. The click appends its Main reservation synchronously, so every
   * pre-click mutation precedes it and every post-click mutation follows it.
   */
  enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#draftMutationTail.then(operation);
    this.#draftMutationTail = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  /** Sequences one Main draft command and observes the epoch of its receipt. */
  run<Receipt extends DraftEpochReceipt>(
    command: (lease: SessionBoundChatLease) => Promise<Receipt>
  ): Promise<Receipt> {
    return this.enqueue(() =>
      this.#lease.runWhenReady(async (lease) => {
        const receipt = await command(lease);
        this.observeDraftEpoch(receipt);
        return receipt;
      })
    );
  }
}
