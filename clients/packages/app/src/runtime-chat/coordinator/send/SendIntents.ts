import type {
  ChatBeginSendIntentReceipt,
  ChatCommandReceipt,
  ChatLeasedBeginSendIntentInput,
  ChatLeasedSendInput,
  ChatTarget,
} from "@comma/chat-contract";
import type { ChatEntries } from "../entries/ChatEntries";
import { chatKey } from "../entries/chatEntry";
import type { ChatPublisher } from "../entries/ChatPublisher";
import { isSameLiveBoundary } from "../entries/sessionBoundary";
import type { ChatCoordinatorOptions } from "../hostContract";
import { commitSend } from "./sendCommit";
import { assertNotSent, isReservedBy } from "./sendGates";

// Modeled in tla/connector/AttachmentSendIntent.tla: the host owns the immutable
// send reservation, exact intake outcomes, replay fences, and commit point.
export class SendIntents {
  readonly #entries: ChatEntries;
  readonly #getClientDeviceId: ChatCoordinatorOptions["getClientDeviceId"];
  readonly #publisher: ChatPublisher;

  constructor(
    entries: ChatEntries,
    { getClientDeviceId }: Pick<ChatCoordinatorOptions, "getClientDeviceId">
  ) {
    this.#entries = entries;
    this.#getClientDeviceId = getClientDeviceId;
    this.#publisher = entries.publisher;
  }

  begin(input: ChatLeasedBeginSendIntentInput): ChatBeginSendIntentReceipt {
    const entry = this.#entries.required(input);
    assertNotSent(entry, input.sendIntentId);
    const active = entry.activeSendIntent;
    if (active) {
      if (!isReservedBy(active, input)) {
        throw new Error("A send is already in progress for this draft.");
      }
      return {
        draftEpoch: active.draftEpoch,
        revision: this.#publisher.revision,
        sendIntentId: active.sendIntentId,
      };
    }
    entry.activeSendIntent = {
      committing: false,
      draftEpoch: entry.draftEpoch,
      leaseId: input.leaseId,
      sendIntentId: input.sendIntentId,
      subscriberId: input.subscriberId,
      surfaceId: input.surfaceId,
    };
    entry.boundary.assertCurrent();
    return {
      draftEpoch: entry.draftEpoch,
      revision: this.#publisher.revision,
      sendIntentId: input.sendIntentId,
    };
  }

  cancel(input: ChatLeasedBeginSendIntentInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    const active = entry.activeSendIntent;
    if (!active || !isReservedBy(active, input)) {
      return this.#publisher.receipt(entry);
    }
    if (active.committing) {
      throw new Error("A committing send intent cannot be cancelled.");
    }
    entry.activeSendIntent = undefined;
    entry.boundary.assertCurrent();
    return this.#publisher.receipt(entry);
  }

  send(input: ChatLeasedSendInput): Promise<ChatCommandReceipt> {
    return commitSend(this.#entries, input);
  }

  // Sends outside the renderer's draft lease, for Main-owned surfaces such as
  // a notification reply. The send-intent fence guards renderer draft
  // ownership, which a detached send never touches.
  async sendDetached(target: ChatTarget, text: string): Promise<void> {
    const boundary = this.#entries.openBoundary();
    boundary.assertCurrent();
    const entry = this.#entries.get(chatKey(target));
    if (entry && isSameLiveBoundary(entry.boundary, boundary)) {
      await entry.channel.send(text, { consumeDraft: false });
      return;
    }
    const clientDeviceId = this.#getClientDeviceId?.(target.workspaceId);
    await boundary.api.sendMessage(target.groupId, target.conversationId, {
      text,
      ...(clientDeviceId ? { clientDeviceId } : {}),
    });
  }
}
