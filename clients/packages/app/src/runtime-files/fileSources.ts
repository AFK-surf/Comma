import type { CommaApiClient } from "../api";

/** A message attachment keeps its original conversation as the byte authority. */
export interface ConversationFileSource {
  groupId: string;
  conversationId: string;
  messageId: string;
  attachmentIndex: number;
  fileName: string;
  mimeType?: string;
  size?: number;
}

export const conversationFileSourceKey = (source: ConversationFileSource) =>
  JSON.stringify([
    source.groupId,
    source.conversationId,
    source.messageId,
    source.attachmentIndex,
    source.fileName,
  ]);

export const resolveConversationFile = (
  api: CommaApiClient,
  source: ConversationFileSource,
  signal?: AbortSignal
) =>
  api.fetchConversationAttachment(
    source.groupId,
    source.conversationId,
    source.messageId,
    source.attachmentIndex,
    signal ? { signal } : {}
  );
