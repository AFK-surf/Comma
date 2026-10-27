import { inlineMediaKindOf } from "../../../../../runtime-files/inlineMedia";
import type { ChatAttachment, ChatImagePreviewRef } from "@comma/core/chat";
import { MAX_ATTACHMENT_BYTES } from "@comma/core/chat";

export function agentBlobImagePreviewRef(
  attachment: ChatAttachment
): ChatImagePreviewRef | undefined {
  if (
    (attachment.blockType !== "image" && inlineMediaKindOf(attachment) !== "image") ||
    !attachment.agentId ||
    !attachment.blobRef ||
    attachment.blobRef.size <= 0 ||
    attachment.blobRef.size > MAX_ATTACHMENT_BYTES
  ) {
    return undefined;
  }
  const fileName =
    attachment.fileName ?? attachment.workspacePath?.split("/").at(-1) ?? "attachment";
  const mediaType = imagePreviewMediaType(attachment.mimeType, fileName);
  if (!fileName || !mediaType) return undefined;
  return {
    agentId: attachment.agentId,
    blobRef: attachment.blobRef,
    fileName,
    kind: "agent-blob",
    mediaType,
  };
}

/** A message's image by its place in it, when that is all there is to read it by. */
export function messageImagePreviewRef(
  attachment: ChatAttachment,
  messageId: string
): ChatImagePreviewRef | undefined {
  if (attachment.blockType !== "image" || attachment.attachmentIndex === undefined)
    return undefined;
  const fileName = attachment.fileName ?? attachment.title;
  if (!fileName || !imagePreviewMediaType(attachment.mimeType, fileName))
    return undefined;
  return { fileName, index: attachment.attachmentIndex, kind: "attachment", messageId };
}

function imagePreviewMediaType(
  value: string | undefined,
  fileName: string | undefined
): "image/png" | "image/jpeg" | "image/gif" | "image/webp" | undefined {
  const normalized = value?.trim().toLowerCase();
  if (
    normalized === "image/png" ||
    normalized === "image/jpeg" ||
    normalized === "image/gif" ||
    normalized === "image/webp"
  ) {
    return normalized;
  }
  const extension = fileName?.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1];
  if (extension === "png") return "image/png";
  if (extension === "jpg" || extension === "jpeg") return "image/jpeg";
  if (extension === "gif") return "image/gif";
  if (extension === "webp") return "image/webp";
  return undefined;
}

export function imagePreviewRefKey(ref: ChatImagePreviewRef) {
  if (typeof ref === "string") return ref;
  if (ref.kind === "attachment") return `${ref.messageId}#${ref.index}`;
  return `${ref.agentId}:${ref.blobRef.uuid}:${ref.blobRef.hash}:${ref.blobRef.size}`;
}
