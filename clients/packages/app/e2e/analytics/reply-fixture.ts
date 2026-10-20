import { createConversationAnalytics } from "../../src/analytics/experience";
import {
  idleConversationChannelState,
  type ConversationChannelState,
} from "@comma/core/chat";

// Exercise the production observer and SDK together, with private conversation data.
export function showReply() {
  const observe = createConversationAnalytics("route");
  const baseline: ConversationChannelState = {
    ...idleConversationChannelState,
    status: "ready",
    connection: "live",
  };
  observe(baseline, true);
  const waiting: ConversationChannelState = {
    ...baseline,
    awaitingReply: true,
    awaitingTurnKey: "turn-private",
    messages: [
      {
        messageId: "msg1_1234567890123456789",
        clientRequestId: "turn-private",
        role: "user",
        text: "private question",
        attachments: [],
        refs: [],
        createdAt: 1,
        delivery: "sent",
        source: "server",
      },
    ],
  };
  observe(waiting, true);
  const reply: ConversationChannelState = {
    ...waiting,
    assistantDraft: {
      conversationId: "conversation-private",
      draftId: "draft-private",
      responseKey: "response-private",
      sourceMessageIds: ["msg1_1234567890123456789"],
      status: "streaming",
      text: "private answer",
    },
  };
  observe(reply, true);
  observe(reply, true);
}
