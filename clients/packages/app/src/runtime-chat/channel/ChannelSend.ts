import { getNativeBridge } from "@comma/native-bridge";
import type { DraftAttachments } from "./attachments/DraftAttachments";
import type { ChannelLease } from "./ChannelLease";
import type { ChannelStore } from "./channelStore";
import type { ChatSendOptions } from "./ChatChannel";
import type { ChannelDraft } from "./draft/ChannelDraft";
import type { DraftCommands } from "./DraftCommands";

type AcceptedSendOperation = Promise<unknown> & {
  accepted: Promise<void>;
};

/**
 * This surface's sends. A send is accepted once Main reserved its intent and
 * every draft attachment it carries has settled; Main owns it from there.
 */
export class ChannelSend {
  readonly #attachments: DraftAttachments;
  readonly #commands: DraftCommands;
  readonly #draft: ChannelDraft;
  readonly #lease: ChannelLease;
  readonly #store: ChannelStore;
  readonly #surfaceId: string;

  constructor(channel: {
    attachments: DraftAttachments;
    commands: DraftCommands;
    draft: ChannelDraft;
    lease: ChannelLease;
    store: ChannelStore;
    surfaceId: string;
  }) {
    this.#attachments = channel.attachments;
    this.#commands = channel.commands;
    this.#draft = channel.draft;
    this.#lease = channel.lease;
    this.#store = channel.store;
    this.#surfaceId = channel.surfaceId;
  }

  send(text: string, options: ChatSendOptions) {
    let resolveCompletion!: (value: unknown) => void;
    let rejectCompletion!: (error: unknown) => void;
    const completion = new Promise<unknown>((resolve, reject) => {
      resolveCompletion = resolve;
      rejectCompletion = reject;
    });
    const ready = this.#lease.ready;
    const sendIntentId = crypto.randomUUID();
    const intent =
      this.#lease.active && ready
        ? this.#commands.run((lease) =>
            getNativeBridge().chat.beginSendIntent({
              ...lease,
              sendIntentId,
              surfaceId: this.#surfaceId,
            })
          )
        : undefined;
    const accepted =
      !this.#lease.active || !ready || !intent
        ? Promise.reject<void>(new Error("Chat bridge is not retained."))
        : this.#acceptSend({
            generation: this.#lease.generation,
            intent,
            onCompletion: (nativeCompletion) => {
              void nativeCompletion.then(resolveCompletion, rejectCompletion);
            },
            options,
            ready,
            sendIntentId,
            text,
          }).catch(async (error) => {
            // A reservation that fails before chat.send is invoked must not
            // strand Main's all-path single-flight. Cancellation is exact-id
            // and therefore cannot affect a successor intent.
            try {
              await intent;
              await getNativeBridge().chat.cancelSendIntent({
                ...this.#lease.requiredLease(this.#lease.generation),
                sendIntentId,
                surfaceId: this.#surfaceId,
              });
            } catch {
              // Lease release/disposal is the fallback owner for a lost
              // renderer; preserve the original admission error.
            }
            throw error;
          });

    void accepted.catch(rejectCompletion);
    // Most composer callers intentionally fire and forget. Observing this
    // branch prevents an unhandled rejection without changing the completion
    // promise returned to callers that do need end-to-end semantics.
    void completion.catch(() => undefined);
    return Object.assign(completion, { accepted }) satisfies AcceptedSendOperation;
  }

  async #acceptSend({
    generation,
    intent,
    onCompletion,
    options,
    ready,
    sendIntentId,
    text,
  }: {
    generation: number;
    intent: Promise<{ draftEpoch: number; sendIntentId: string }>;
    onCompletion(completion: Promise<unknown>): void;
    options: ChatSendOptions;
    ready: Promise<void>;
    sendIntentId: string;
    text: string;
  }) {
    await ready;
    const reservation = await intent;
    if (!this.#lease.active || generation !== this.#lease.generation) {
      throw new Error("Chat bridge is not retained.");
    }
    // Main's receipt proves the click-sequenced reservation completed. The
    // commit still carries the caller's id, which Main matches against the
    // exact active reservation; Renderer never supplies an epoch.
    void reservation;

    if (options.consumeDraft !== false) {
      const attachments = this.#attachments.sendSettlement();
      while (true) {
        await attachments.round();
        if (!this.#lease.active || generation !== this.#lease.generation) {
          throw new Error("Chat bridge is not retained.");
        }
        if (attachments.moved()) {
          continue;
        }
        attachments.assertSendable();
        break;
      }
    }

    // Invocation is the renderer acceptance boundary. Main owns the pending
    // row from here, including a later 402/500 transition to `failed`.
    if (options.consumeDraft !== false && this.#store.state.draft === text) {
      this.#draft.handOver();
    }
    const nativeCompletion = getNativeBridge()
      .chat.send({
        ...this.#lease.requiredLease(generation),
        sendIntentId,
        ...(options.consumeDraft === false ? { consumeDraft: false as const } : {}),
        ...(options.replyToMessageId
          ? { replyToMessageId: options.replyToMessageId }
          : {}),
        ...(options.skills ? { skills: options.skills } : {}),
        surfaceId: this.#surfaceId,
        text,
      })
      .then((receipt) => {
        this.#commands.observeDraftEpoch(receipt);
        return receipt;
      });
    onCompletion(nativeCompletion);
  }
}
