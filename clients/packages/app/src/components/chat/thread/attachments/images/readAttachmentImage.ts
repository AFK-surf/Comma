import type { ChatAttachment } from "../../../model/conversationChannel";
import { isGroupImagePreviewPath } from "../../../model/protocol";
import type { ThreadFileSource } from "../../threadContexts";

/** Reads a previewed image's bytes from the source the attachment arrived through. */
export async function readAttachmentImage(
  {
    attachment,
    messageId,
    previewUrl,
    sourceContext,
  }: {
    attachment: ChatAttachment;
    messageId: string;
    previewUrl: string;
    sourceContext: ThreadFileSource | undefined;
  },
  signal?: AbortSignal
) {
  if (sourceContext && attachment.attachmentIndex !== undefined) {
    return sourceContext.api.fetchConversationAttachment(
      sourceContext.groupId,
      sourceContext.conversationId,
      messageId,
      attachment.attachmentIndex,
      signal ? { signal } : {}
    );
  }
  if (sourceContext) {
    const options = signal ? { signal } : {};
    if (attachment.agentId && attachment.blobRef) {
      return sourceContext.api.fetchAgentBlob(
        sourceContext.groupId,
        attachment.agentId,
        attachment.blobRef,
        options
      );
    }
    if (attachment.workspacePath && isGroupImagePreviewPath(attachment.workspacePath)) {
      return sourceContext.api.fetchGroupFile(
        sourceContext.groupId,
        attachment.workspacePath,
        options
      );
    }
  }
  const response = await fetch(previewUrl, {
    signal: signal ?? null,
  });
  if (!response.ok) throw new Error("Image could not be read.");
  return response.blob();
}
