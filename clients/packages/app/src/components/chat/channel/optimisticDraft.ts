/**
 * Orders one surface's optimistic draft edits against Main's draft
 * publications, which Main versions with its draft epoch.
 *
 * While an edit is in flight, the local text is newer than anything Main has
 * published. Once every edit is settled, a publication at least as new as the
 * last acknowledged edit is Main's current draft: the echo of this surface's
 * own edit, or a change from another surface or a send that consumed the
 * draft. Ordering by epoch rather than by text keeps a late echo from
 * restoring text that was typed and then deleted.
 */
export class OptimisticDraft {
  #editsInFlight = 0;
  #acknowledgedEpoch = -1;
  #published: { draft: string; epoch: number } | undefined;

  beginEdit() {
    this.#editsInFlight += 1;
  }

  /**
   * Main applied the edit. A receipt without an epoch cannot be ordered
   * against later publications, so the local text keeps precedence.
   */
  acknowledgeEdit(epoch: number | undefined) {
    this.#editsInFlight -= 1;
    this.#acknowledgedEpoch = Math.max(
      this.#acknowledgedEpoch,
      epoch ?? Number.POSITIVE_INFINITY
    );
  }

  /** Main refused the edit, so its published draft stands. */
  rejectEdit() {
    this.#editsInFlight -= 1;
  }

  /**
   * The local text was sent as-is, so it has no remaining claim: Main's next
   * publication (the consumed draft, or its successor) decides the text.
   */
  handOver() {
    this.#acknowledgedEpoch = -1;
  }

  /** Records Main's draft; an older epoch than one already seen is ignored. */
  observe(draft: string, epoch = -1) {
    if (this.#published && epoch < this.#published.epoch) return;
    this.#published = { draft, epoch };
  }

  /** Main's draft when it may replace the local text, otherwise undefined. */
  adoptable() {
    if (this.#editsInFlight > 0 || !this.#published) return undefined;
    return this.#published.epoch >= this.#acknowledgedEpoch
      ? this.#published.draft
      : undefined;
  }
}
