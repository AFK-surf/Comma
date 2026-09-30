import { useEffect, useState } from "react";
import type { ChatAttachment } from "../../../model/conversationChannel";
import type { ImagePreviews } from "./useImagePreviews";
import type { ImagePreviewTargets } from "./useImagePreviewTargets";

export function useImageGroupReveal({
  attachments,
  images: { failedPreviewKeys, groupedImages, pendingPreviewKeys, previews },
  showImages,
  targets: { imagePositions, previewImages },
}: {
  attachments: ChatAttachment[];
  images: ImagePreviews;
  showImages: boolean;
  targets: ImagePreviewTargets;
}) {
  // The image count the message last revealed with; before the first reveal
  // the full attachment count holds so an early failure cannot reshape the
  // placeholder mid-settle.
  const [revealedImageCount, setRevealedImageCount] = useState<number | undefined>();
  const unpreviewableImageCount = attachments.filter(
    (_attachment, position) =>
      showImages &&
      imagePositions.has(position) &&
      !previewImages.some((item) => item.position === position)
  ).length;
  const imageGroupSettled =
    pendingPreviewKeys.length === 0 && unpreviewableImageCount === 0;
  const revealed = imageGroupSettled || revealedImageCount !== undefined;
  const totalImageCount = attachments.filter(
    (_attachment, position) => showImages && imagePositions.has(position)
  ).length;
  const placeholderImageCount = revealedImageCount ?? totalImageCount;

  useEffect(() => {
    if (imageGroupSettled) setRevealedImageCount(groupedImages.length);
  }, [groupedImages.length, imageGroupSettled]);

  const unavailableImageAttachments = revealed
    ? attachments.flatMap((attachment, position) => {
        if (!showImages || !imagePositions.has(position)) return [];
        const previewImage = previewImages.find((item) => item.position === position);
        if (!previewImage) return [];
        const preview = previews.get(previewImage.key);
        return failedPreviewKeys.has(previewImage.key) ||
          preview?.status === "unavailable"
          ? [{ attachment, position }]
          : [];
      })
    : [];
  return { imageGroupSettled, placeholderImageCount, unavailableImageAttachments };
}
