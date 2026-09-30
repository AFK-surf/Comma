import { ProductInboxRuntime } from "@comma/product-inbox-runtime";
import { SessionHistoryRuntime } from "@comma/session-history-runtime";
import { ChatCoordinator } from "./coordinator/ChatCoordinator";

/** One product runtime per host. Platforms supply credentials, storage and native effects. */
export class CommaAppRuntime {
  readonly chat: ChatCoordinator;
  readonly productInbox: ProductInboxRuntime;
  readonly sessionHistory: SessionHistoryRuntime;
  constructor(options: {
    chat: ConstructorParameters<typeof ChatCoordinator>[0];
    productInbox: ConstructorParameters<typeof ProductInboxRuntime>[0];
    sessionHistory: ConstructorParameters<typeof SessionHistoryRuntime>[0];
  }) {
    this.chat = new ChatCoordinator(options.chat);
    this.productInbox = new ProductInboxRuntime(options.productInbox);
    this.sessionHistory = new SessionHistoryRuntime(options.sessionHistory);
  }
  close() {
    this.chat.close();
    this.productInbox.close();
    this.sessionHistory.close();
  }
}
