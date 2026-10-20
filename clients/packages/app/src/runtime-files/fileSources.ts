import type { CallFn, FileSource } from "@comma/core-client";

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

/** A chat file's bytes as the core reads them, typed as the server gave them. */
export const readFileBlob = async (
  call: CallFn,
  source: FileSource,
  signal?: AbortSignal
) => {
  const { bytes, type } = await call("files.read", source, signal);
  return new Blob([bytes as Uint8Array<ArrayBuffer>], { type });
};

export const resolveConversationFile = (
  call: CallFn,
  source: ConversationFileSource,
  signal?: AbortSignal
) =>
  readFileBlob(
    call,
    {
      source: "attachment",
      group: source.groupId,
      conversation: source.conversationId,
      message: source.messageId,
      index: source.attachmentIndex,
    },
    signal
  );
