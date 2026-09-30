import type {
  ChatCommandReceipt,
  ChatLeasedClientRequestInput,
  ChatLeasedTarget,
} from "@comma/chat-contract";
import type { ChatEntries } from "./entries/ChatEntries";
import { chatKey } from "./entries/chatEntry";
import type { ChatPublisher } from "./entries/ChatPublisher";
import type { SideChatTargets } from "./entries/SideChatTargets";

/**
 * Leased commands on the conversation itself rather than its draft, so their
 * receipts carry no draft epoch.
 */
export class ConversationCommands {
  readonly #entries: ChatEntries;
  readonly #publisher: ChatPublisher;
  readonly #sideChat: SideChatTargets;

  constructor(entries: ChatEntries) {
    this.#entries = entries;
    this.#publisher = entries.publisher;
    this.#sideChat = entries.sideChat;
  }

  presentInSideChat(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    this.#sideChat.present(chatKey(input));
    this.#publisher.publish();
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  async retry(input: ChatLeasedClientRequestInput): Promise<ChatCommandReceipt> {
    const entry = this.#entries.required(input);
    await entry.channel.retry(input.clientRequestId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  discard(input: ChatLeasedClientRequestInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.discard(input.clientRequestId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  async acceptTaskReview(
    input: ChatLeasedTarget & { reviewVersion: number }
  ): Promise<ChatCommandReceipt> {
    const entry = this.#entries.required(input);
    await entry.channel.acceptTaskReview(input.reviewVersion);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  refresh(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.refresh();
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }
}
