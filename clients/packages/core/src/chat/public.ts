// What a UI may use of chat (`@comma/core/chat`): the message shapes the core sends and the pure helpers that word
// and lay them out. Effect-free, and no requests: the conversation itself is the core's (its `chat` topics and calls).
export * from "./model/protocol";
export * from "./model/userMessageText";
export * from "./model/attachmentQuota";
export { projectionToChannelState } from "./view-state";
export * from "./model/mentionSerialization";
export * from "./model/visibleReplyPresentation";
export * from "./model/inlineElementContract";
export * from "./model/channelStateChange";
export { taskActivity, transcriptMessages } from "./model/taskActivity";
export {
  QUICK_CHAT_MESSAGE_TYPE,
  announcesTasks,
  asksRouter,
  idleConversationChannelState,
  createdTasksOf,
  messageReading,
  normalizeServerMessages,
  replyState,
  taskRun,
  toConversationProjection,
} from "./model/conversationChannel";
export type * from "./model/conversationChannel";
export type { CommaLocalFileRef } from "./api";
