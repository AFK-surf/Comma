import type { ChatRetainInput, ChatTarget } from "@comma/chat-contract";
import { getNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type { ChannelStore } from "./channelStore";

export type SessionBoundChatLease = ChatRetainInput & {
  session: SessionProductLease;
};

/** Where a started lease delivers what Main publishes and replies. */
export type ChannelLeaseHandlers = {
  applyDraftsEnvelope(envelope: unknown): void;
  applyEnvelope(envelope: unknown): void;
  observeDraftEpoch(receipt: { draftEpoch?: number | undefined }): void;
};

/**
 * The channel's lease on its Main-owned session entry. Each start opens a new
 * lifecycle generation; commands and replies of an older one are stale.
 */
export class ChannelLease {
  readonly #presentInSideChat: boolean;
  readonly #session: SessionProductLease;
  readonly #store: ChannelStore;
  readonly #subscriberId: string;
  readonly #target: ChatTarget;
  #active = false;
  #generation = 0;
  #lease: SessionBoundChatLease | undefined;
  #ready: Promise<void> | undefined;
  #releaseDrafts: (() => void) | undefined;
  #releaseState: (() => void) | undefined;
  #retainReceipt: Promise<unknown> | undefined;

  constructor(options: {
    presentInSideChat: boolean;
    session: SessionProductLease;
    store: ChannelStore;
    subscriberId: string;
    target: ChatTarget;
  }) {
    this.#presentInSideChat = options.presentInSideChat;
    this.#session = options.session;
    this.#store = options.store;
    this.#subscriberId = options.subscriberId;
    this.#target = options.target;
  }

  get active() {
    return this.#active;
  }

  get generation() {
    return this.#generation;
  }

  get ready() {
    return this.#ready;
  }

  start({
    applyDraftsEnvelope,
    applyEnvelope,
    observeDraftEpoch,
  }: ChannelLeaseHandlers) {
    this.#active = true;
    const generation = ++this.#generation;
    const lease: SessionBoundChatLease = {
      ...this.#target,
      leaseId: crypto.randomUUID(),
      session: this.#session,
      subscriberId: this.#subscriberId,
    };
    this.#lease = lease;
    const bridge = getNativeBridge();
    this.#releaseState = bridge.chat.state.subscribe(
      (envelope) => {
        if (this.isCurrent(generation, lease)) {
          applyEnvelope(envelope);
        }
      },
      { session: this.#session }
    );
    this.#releaseDrafts = bridge.chat.drafts.subscribe(
      (envelope) => {
        if (this.isCurrent(generation, lease)) {
          applyDraftsEnvelope(envelope);
        }
      },
      { session: this.#session }
    );
    const retainReceipt = bridge.chat.retain(lease);
    this.#retainReceipt = retainReceipt;
    const ready = retainReceipt
      .then((receipt) => {
        this.assertCurrent(generation, lease);
        // Every retain receipt carries the Main-owned draft epoch, so the
        // shadow is always populated before the first send can be decided.
        observeDraftEpoch(receipt);
        return bridge.chat.state.get({ session: this.#session });
      })
      .then((envelope) => {
        if (this.isCurrent(generation, lease)) {
          applyEnvelope(envelope);
        }
      });
    this.#ready = ready;
    void ready.catch((error) => this.applyBridgeError(error, generation));
    if (this.#presentInSideChat) {
      void this.runWhenReady((currentLease) =>
        bridge.chat.presentInSideChat(currentLease)
      );
    }
  }

  /** Ends the lifecycle: whatever it still has in flight is stale from now on. */
  end() {
    this.#active = false;
    this.#generation += 1;
  }

  /** Drops the ended lifecycle's lease, releasing it once Main retained it. */
  release() {
    const ready = this.#ready;
    const retainReceipt = this.#retainReceipt;
    const lease = this.#lease;
    this.#ready = undefined;
    this.#retainReceipt = undefined;
    this.#lease = undefined;
    this.#releaseState?.();
    this.#releaseState = undefined;
    this.#releaseDrafts?.();
    this.#releaseDrafts = undefined;
    if (retainReceipt && lease) {
      void retainReceipt.then(
        () => getNativeBridge().chat.release(lease),
        () => undefined
      );
    } else if (ready && lease) {
      void ready.then(
        () => getNativeBridge().chat.release(lease),
        () => undefined
      );
    }
  }

  runWhenReady<T>(operation: (lease: SessionBoundChatLease) => Promise<T>): Promise<T> {
    const ready = this.#ready;
    const lease = this.#lease;
    const generation = this.#generation;
    if (!this.#active || !ready || !lease) {
      return Promise.reject(new Error("Chat bridge is not retained."));
    }
    const result = ready.then(() => {
      this.assertCurrent(generation, lease);
      return operation(lease);
    });
    void result.catch((error) => this.applyBridgeError(error, generation));
    return result;
  }

  requiredLease(generation: number) {
    const lease = this.#lease;
    if (!lease) {
      throw new Error("Chat bridge is not retained.");
    }
    this.assertCurrent(generation, lease);
    return lease;
  }

  assertCurrent(generation: number, lease: SessionBoundChatLease) {
    if (!this.isCurrent(generation, lease)) {
      throw new Error("Chat bridge is not retained.");
    }
  }

  isCurrent(generation: number, lease: SessionBoundChatLease) {
    return this.#active && generation === this.#generation && lease === this.#lease;
  }

  applyBridgeError(_error: unknown, generation = this.#generation) {
    if (!this.#active || generation !== this.#generation) {
      return;
    }
    this.#store.patch({ errorKind: "network", status: "error", syncWarning: "stale" });
  }
}

/** Whether an envelope was published for this channel's product lease. */
export function sameSessionProductLease(
  left: SessionProductLease,
  right: SessionProductLease
) {
  return (
    left.authorityInstanceId === right.authorityInstanceId &&
    left.generation === right.generation &&
    left.sessionId === right.sessionId &&
    left.audience === right.audience
  );
}
