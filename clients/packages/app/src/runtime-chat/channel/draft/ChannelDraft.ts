import { chatRuntimeDraftsEnvelopeSchema, getNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { sameSessionProductLease } from "../ChannelLease";
import type { ChannelStore } from "../channelStore";
import type { DraftCommands } from "../DraftCommands";
import { OptimisticDraft } from "./optimisticDraft";

/**
 * This surface's draft text: shown optimistically while its edits travel to
 * Main, and replaced by Main's draft once no edit can still be newer.
 */
export class ChannelDraft {
  readonly #commands: DraftCommands;
  readonly #key: string;
  readonly #session: SessionProductLease;
  readonly #store: ChannelStore;
  readonly #surfaceId: string;
  #draft = new OptimisticDraft();

  constructor(options: {
    commands: DraftCommands;
    key: string;
    session: SessionProductLease;
    store: ChannelStore;
    surfaceId: string;
  }) {
    this.#commands = options.commands;
    this.#key = options.key;
    this.#session = options.session;
    this.#store = options.store;
    this.#surfaceId = options.surfaceId;
  }

  /** Forgets every edit and publication, as for a new or lost session. */
  reset() {
    this.#draft = new OptimisticDraft();
  }

  set(draft: string) {
    const optimistic = this.#draft;
    optimistic.beginEdit();
    this.#store.patch({ draft });
    const operation = this.#commands.run((lease) =>
      getNativeBridge().chat.setDraft({
        ...lease,
        draft,
        surfaceId: this.#surfaceId,
      })
    );
    void operation.then(
      (receipt) => {
        optimistic.acknowledgeEdit(receipt.draftEpoch);
        if (optimistic === this.#draft) this.#adoptMainDraft();
      },
      () => {
        optimistic.rejectEdit();
        if (optimistic === this.#draft) this.#adoptMainDraft();
      }
    );
    return operation;
  }

  applyDraftsEnvelope(value: unknown) {
    const envelope = chatRuntimeDraftsEnvelopeSchema.safeParse(value);
    if (
      !envelope.success ||
      !sameSessionProductLease(envelope.data.session, this.#session)
    ) {
      return;
    }
    const published = envelope.data.snapshot.drafts.find(
      (item) => item.key === this.#key
    );
    if (!published) return;
    this.#draft.observe(published.draft, published.draftEpoch);
    this.#adoptMainDraft();
  }

  /** Records Main's projected draft; returns it unless an edit here is newer. */
  adopt(draft: string, draftEpoch: number | undefined) {
    this.#commands.observeDraftEpoch({ draftEpoch });
    this.#draft.observe(draft, draftEpoch);
    return this.#draft.adoptable();
  }

  /** The draft text was sent as-is, so Main's next draft decides the text. */
  handOver() {
    this.#draft.handOver();
  }

  /** Shows Main's draft once no edit of this surface can still be newer. */
  #adoptMainDraft() {
    const draft = this.#draft.adoptable();
    if (draft === undefined || draft === this.#store.state.draft) return;
    this.#store.patch({ draft });
  }
}
