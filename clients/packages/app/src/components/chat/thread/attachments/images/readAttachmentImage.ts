import type { CallFn } from "@comma/core-client";
import type { ChatAttachment } from "@comma/core/chat";
import { isGroupImagePreviewPath } from "@comma/core/chat";
import { readFileBlob } from "../../../../../runtime-files/fileSources";
import type { ThreadFileSource } from "../../threadContexts";

/** Reads a previewed image's bytes from the source the attachment arrived through. */
export async function readAttachmentImage(
  {
    attachment,
    call,
    messageId,
    previewUrl,
    sourceContext,
  }: {
    attachment: ChatAttachment;
    call: CallFn;
    messageId: string;
    previewUrl: string;
    sourceContext: ThreadFileSource | undefined;
  },
  signal?: AbortSignal
) {
  if (sourceContext) {
    const group = sourceContext.groupId;
    if (attachment.attachmentIndex !== undefined)
      return readFileBlob(
        call,
        {
          source: "attachment",
          group,
          conversation: sourceContext.conversationId,
          message: messageId,
          index: attachment.attachmentIndex,
        },
        signal
      );
    if (attachment.agentId && attachment.blobRef)
      return readFileBlob(
        call,
        {
          source: "agent-blob",
          group,
          agent: attachment.agentId,
          blobRef: attachment.blobRef,
        },
        signal
      );
    if (attachment.workspacePath && isGroupImagePreviewPath(attachment.workspacePath))
      return readFileBlob(
        call,
        { source: "group-file", group, path: attachment.workspacePath },
        signal
      );
  }
  // A file on this device: its preview is all the renderer has.
  const response = await fetch(previewUrl, {
    signal: signal ?? null,
  });
  if (!response.ok) throw new Error("Image could not be read.");
  return response.blob();
}
