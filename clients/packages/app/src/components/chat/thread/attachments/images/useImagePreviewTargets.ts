import { useMemo } from "react";
import type { ChatAttachment } from "../../../model/conversationChannel";
import { isGroupImagePreviewPath } from "../../../model/protocol";
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
  // A promoted file block must already have a byte source: an image with none
  // would hold the group's placeholder open where a file card used to be.
  const imagePositions = useMemo(
    () =>
      new Set(
        attachments.flatMap((attachment, position) =>
          attachment.blockType === "image" ||
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
        const previewRef =
          agentBlobImagePreviewRef(attachment) ??
          attachment.localFileRef ??
          attachment.workspacePath;
        if (
          !showImages ||
          !imagePositions.has(position) ||
          !previewRef ||
          (typeof previewRef === "string" &&
            !isLocalFilePreviewRef(previewRef) &&
            !isGroupImagePreviewPath(previewRef)) ||
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
