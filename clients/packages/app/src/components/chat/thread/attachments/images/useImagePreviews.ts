import { useCommaMessages } from "@comma/i18n/react";
import type { ChatPanelImageGroupImage } from "@comma/ui";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type SyntheticEvent,
} from "react";
import { MediaMenuContext } from "../../../../file-preview/useMediaContextMenu";
import type { ChatAttachment } from "../../../model/conversationChannel";
import {
  useLocalFilePreviews,
  type LocalFilePreviewLoader,
} from "../useLocalFilePreviews";
import type { ThreadFileSource } from "../../threadContexts";
import { attachmentLabel } from "../attachmentLabels";
import { schedulePreviewSettleDeadline } from "./previewSettleDeadline";
import { readAttachmentImage } from "./readAttachmentImage";
import type { ImagePreviewTargets } from "./useImagePreviewTargets";

export type ImagePreviews = ReturnType<typeof useImagePreviews>;

export function useImagePreviews({
  attachments,
  messageId,
  nearViewport,
  onPreviewLocalFile,
  showImages,
  sourceContext,
  targets: { imagePositions, previewImages },
}: {
  attachments: ChatAttachment[];
  messageId: string;
  nearViewport: boolean;
  onPreviewLocalFile: LocalFilePreviewLoader | undefined;
  showImages: boolean;
  sourceContext: ThreadFileSource | undefined;
  targets: ImagePreviewTargets;
}) {
  const messagesApi = useCommaMessages();
  // Previews that settled without an image for the life of this message:
  // decode errors, loaders that answered "unavailable", and loaders that
  // outlived the settle deadline. They are never requested again, so the
  // fallback card and the reserved geometry stay put across every re-entry.
  const [failedPreviewKeys, setFailedPreviewKeys] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const pendingPreviewSinceRef = useRef(new Map<string, number>());
  const previewRequests = useMemo(
    () =>
      previewImages.flatMap(({ key, previewRef }) =>
        failedPreviewKeys.has(key) ? [] : [{ key, previewRef }]
      ),
    [failedPreviewKeys, previewImages]
  );
  const previews = useLocalFilePreviews(
    previewRequests,
    onPreviewLocalFile,
    nearViewport
  );

  const openImageMenu = useContext(MediaMenuContext);
  const groupedPreviews = useMemo(
    () =>
      attachments.flatMap((attachment, position) => {
        if (!showImages || !imagePositions.has(position)) return [];
        const previewImage = previewImages.find((item) => item.position === position);
        if (!previewImage || failedPreviewKeys.has(previewImage.key)) return [];
        const preview = previews.get(previewImage.key);
        if (preview?.status !== "ready") return [];
        const key = previewImage?.key ?? `${messageId}:${position}`;
        return [
          {
            image: {
              alt: attachmentLabel(attachment, messagesApi),
              src: preview.url,
              ...(openImageMenu
                ? {
                    onContextMenu: (event) =>
                      openImageMenu(event, {
                        fileName: attachmentLabel(attachment, messagesApi),
                        resolve: (signal) =>
                          readAttachmentImage(
                            {
                              attachment,
                              messageId,
                              previewUrl: preview.url,
                              sourceContext,
                            },
                            signal
                          ),
                      }),
                  }
                : {}),
            } satisfies ChatPanelImageGroupImage,
            key,
          },
        ];
      }),
    [
      attachments,
      failedPreviewKeys,
      openImageMenu,
      sourceContext,
      imagePositions,
      messageId,
      messagesApi,
      previewImages,
      previews,
      showImages,
    ]
  );
  const groupedImages = groupedPreviews.map(({ image }) => image);
  // Reveal the initial group together so staggered loads do not resize it
  // card by card. Once ready, its leases remain with this mounted message.
  const settledKeys = previewRequests.flatMap(({ key }) => {
    const status = previews.get(key)?.status;
    return status === "ready" || status === "unavailable" ? [key] : [];
  });
  const pendingPreviewKeys = previewRequests.flatMap(({ key }) =>
    settledKeys.includes(key) ? [] : [key]
  );

  // A loader's "unavailable" is terminal for this message; recording it here
  // keeps the fallback card in place instead of re-requesting on re-entry.
  const unavailableKeys = previewRequests.flatMap(({ key }) =>
    previews.get(key)?.status === "unavailable" ? [key] : []
  );
  const unavailableKeysSignature = unavailableKeys.join("\n");
  useEffect(() => {
    if (!unavailableKeysSignature) return;
    const keys = unavailableKeysSignature.split("\n");
    setFailedPreviewKeys((current) => {
      if (keys.every((key) => current.has(key))) return current;
      const next = new Set(current);
      for (const key of keys) next.add(key);
      return next;
    });
  }, [unavailableKeysSignature]);

  // Bound every requested preview: a key that stays pending past the deadline
  // settles as unavailable so the images that did load are not held hostage.
  // Clocks start when the request starts and reset when the message leaves
  // the retention band, since nothing is in flight while it is released.
  const pendingPreviewKeysSignature = nearViewport ? pendingPreviewKeys.join("\n") : "";
  useEffect(
    () =>
      schedulePreviewSettleDeadline(
        pendingPreviewSinceRef.current,
        pendingPreviewKeysSignature ? pendingPreviewKeysSignature.split("\n") : [],
        (expired) =>
          setFailedPreviewKeys((current) => {
            const next = new Set(current);
            for (const key of expired) next.add(key);
            return next;
          })
      ),
    [pendingPreviewKeysSignature]
  );

  const handlePreviewImageError = useCallback(
    (event: SyntheticEvent<HTMLDivElement>) => {
      const target = event.target;
      if (!(target instanceof HTMLImageElement)) return;
      const failedSource = target.getAttribute("src");
      if (!failedSource) return;
      const matchingKeys = groupedPreviews.flatMap(({ image, key }) =>
        image.src === failedSource ? [key] : []
      );
      if (matchingKeys.length === 0) return;
      setFailedPreviewKeys((current) => {
        if (matchingKeys.every((key) => current.has(key))) return current;
        const next = new Set(current);
        for (const key of matchingKeys) next.add(key);
        return next;
      });
    },
    [groupedPreviews]
  );
  return {
    failedPreviewKeys,
    groupedImages,
    groupedPreviews,
    handlePreviewImageError,
    pendingPreviewKeys,
    previews,
  };
}
