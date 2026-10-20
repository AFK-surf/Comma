import { useMemo } from "react";
import type { ChatAttachment, ChatImagePreviewRef } from "@comma/core/chat";
import { draftUploadPreviewRef, isGroupImagePreviewPath } from "@comma/core/chat";
import {
  isLocalFilePreviewRef,
  type LocalFilePreviewLoader,
} from "../useLocalFilePreviews";
import { agentBlobImagePreviewRef, imagePreviewRefKey } from "./imagePreviewRefs";

export type ImagePreviewTargets = ReturnType<typeof useImagePreviewTargets>;

export function useImagePreviewTargets({
  attachments,
  inlineMediaSection,
  messageId,
  onPreviewLocalFile,
  showImages,
}: {
  attachments: ChatAttachment[];
  inlineMediaSection: boolean;
  messageId: string;
  onPreviewLocalFile: LocalFilePreviewLoader | undefined;
  showImages: boolean;
}) {
  // An image needs a byte source to join the group: one with none (a platform
  // send recorded by name only) would hold the placeholder open forever, so it
  // shows as a file card instead.
  const imagePositions = useMemo(
    () =>
      new Set(
        attachments.flatMap((attachment, position) =>
          (attachment.blockType === "image" &&
            imagePreviewRef(attachment) !== undefined) ||
          (inlineMediaSection &&
            onPreviewLocalFile !== undefined &&
            agentBlobImagePreviewRef(attachment) !== undefined)
            ? [position]
            : []
        )
      ),
    [attachments, inlineMediaSection, onPreviewLocalFile]
  );
  const previewImages = useMemo(
    () =>
      attachments.flatMap((attachment, position) => {
        const previewRef = imagePreviewRef(attachment);
        if (
          !showImages ||
          !imagePositions.has(position) ||
          !previewRef ||
          !onPreviewLocalFile
        ) {
          return [];
        }
        return [
          {
            attachment,
            key: `${messageId}:${position}:${imagePreviewRefKey(previewRef)}`,
            previewRef,
            position,
          },
        ];
      }),
    [attachments, imagePositions, messageId, onPreviewLocalFile, showImages]
  );
  return { imagePositions, previewImages };
}

/** Where an image attachment's bytes can be read from, if anywhere. */
function imagePreviewRef(attachment: ChatAttachment): ChatImagePreviewRef | undefined {
  // An image still uploading shows from the bytes the core holds.
  const uploadingRef = attachment.uploadingId
    ? draftUploadPreviewRef(attachment.uploadingId)
    : undefined;
  const previewRef =
    agentBlobImagePreviewRef(attachment) ??
    uploadingRef ??
    attachment.localFileRef ??
    attachment.workspacePath;
  if (
    typeof previewRef === "string" &&
    previewRef !== uploadingRef &&
    !isLocalFilePreviewRef(previewRef) &&
    !isGroupImagePreviewPath(previewRef)
  ) {
    return undefined;
  }
  return previewRef || undefined;
}
