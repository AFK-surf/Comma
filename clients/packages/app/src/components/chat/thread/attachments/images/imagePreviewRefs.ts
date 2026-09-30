import { inlineMediaKindOf } from "../../../../../runtime-files/inlineMedia";
import type {
  ChatAttachment,
  ChatImagePreviewRef,
} from "../../../model/conversationChannel";
import { MAX_ATTACHMENT_BYTES } from "../../../model/protocol";

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
    attachment.fileName ??
    attachment.title ??
    attachment.workspacePath?.split("/").at(-1);
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
  return `${ref.agentId}:${ref.blobRef.uuid}:${ref.blobRef.hash}:${ref.blobRef.size}`;
}
