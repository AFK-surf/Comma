import { useLayoutEffect, useMemo, useRef, useState, type MouseEvent } from "react";
import type { AiInputAttachment } from "../types";
import type { AiInputImagePreviewProps } from "./AiInputImagePreview";

export interface AttachmentPreview {
  /** Whether the staged attachment opens the preview when pressed. */
  canPreview: (attachmentId: string) => boolean;
  openPreview: (attachmentId: string, event: MouseEvent<HTMLButtonElement>) => void;
  dialogProps: AiInputImagePreviewProps;
}

/** Which staged image, if any, the full-size preview shows. */
export function useAttachmentPreview(
  attachments: AiInputAttachment[]
): AttachmentPreview {
  // Only a settled tile with its own thumbnail can be enlarged. Every one of
  // them shares a single filmstrip, so the preview browses the staged images
  // the same way the sent message's image group does.
  const previewImages = useMemo(
    () =>
      attachments.flatMap((attachment) =>
        attachment.type === "image" &&
        (attachment.state ?? "ready") === "ready" &&
        attachment.thumbnailSrc
          ? [
              {
                alt: attachment.alt ?? attachment.name,
                id: attachment.id,
                src: attachment.thumbnailSrc,
              },
            ]
          : []
      ),
    [attachments]
  );
  // Tracked by id, not position: an attachment that leaves the row while its
  // preview is open takes the preview with it instead of stranding an index.
  const [previewAttachmentId, setPreviewAttachmentId] = useState<string | null>(null);
  const [previewInstantMotion, setPreviewInstantMotion] = useState(false);
  const previewTriggerRef = useRef<HTMLElement | null>(null);
  const previewIndex = previewImages.findIndex(
    (image) => image.id === previewAttachmentId
  );
  // Deriving `isOpen` from the current list closes the overlay immediately,
  // but the selection must end too. Otherwise a temporarily unavailable image
  // can return with the same id and reopen a dialog the user did not request.
  useLayoutEffect(() => {
    if (previewAttachmentId !== null && previewIndex === -1) {
      setPreviewAttachmentId(null);
    }
  }, [previewAttachmentId, previewIndex]);

  return {
    canPreview: (attachmentId) =>
      previewImages.some((image) => image.id === attachmentId),
    openPreview: (attachmentId, event) => {
      previewTriggerRef.current = event.currentTarget;
      setPreviewInstantMotion(event.detail === 0);
      setPreviewAttachmentId(attachmentId);
    },
    dialogProps: {
      images: previewImages,
      index: Math.max(previewIndex, 0),
      instantMotion: previewInstantMotion,
      isOpen: previewIndex !== -1,
      onIndexChange: (next) => setPreviewAttachmentId(previewImages[next]?.id ?? null),
      onOpenChange: (isOpen) => {
        if (!isOpen) setPreviewAttachmentId(null);
      },
      returnFocusRef: previewTriggerRef,
    },
  };
}
