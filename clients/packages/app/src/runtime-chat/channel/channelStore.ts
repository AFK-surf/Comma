import type { ConversationChannelState } from "../../components/chat/model/conversationChannel";

export const idleChannelState: ConversationChannelState = {
  activity: undefined,
  assistantDraft: undefined,
  awaitingReply: false,
  awaitingSince: undefined,
  awaitingTimedOut: false,
  awaitingTurnKey: undefined,
  connection: "idle",
  conversation: undefined,
  draft: "",
  draftAttachments: [],
  errorKind: undefined,
  lastBackoffMs: 0,
  locallyAwaitingReply: false,
  messages: [],
  pending: [],
  participantStatus: undefined,
  serverMessages: [],
  status: "idle",
  syncWarning: undefined,
};

/** The state a channel publishes, and the listeners told when it changes. */
export class ChannelStore {
  state: ConversationChannelState;
  readonly #listeners = new Set<() => void>();

  constructor(state: ConversationChannelState) {
    this.state = state;
  }

  subscribe(listener: () => void) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Replaces some fields of the state, then tells every listener. */
  patch(changes: Partial<ConversationChannelState>) {
    this.state = { ...this.state, ...changes };
    this.emit();
  }

  emit() {
    for (const listener of this.#listeners) {
      listener();
    }
  }
}
