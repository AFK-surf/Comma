import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import type { ChatPanelImageGroupImage } from "@comma/ui/components/chat-panel";
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
import type { ChatAttachment, ChatImagePreviewRef } from "@comma/core/chat";
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

type PreviewRequest = { key: string; previewRef: ChatImagePreviewRef };

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
  const call = useCall();
  // Previews that settled without an image for the life of this message:
  // decode errors, loaders that answered "unavailable", and loaders that
  // outlived the settle deadline. They are never requested again, so the
  // fallback card and the reserved geometry stay put across every re-entry.
  const [failedPreviewKeys, setFailedPreviewKeys] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const pendingPreviewSinceRef = useRef(new Map<string, number>());
  // The last image each position showed. When its source changes (an image
  // that finished uploading is read from the server from then on), the image
  // stays until the new source is ready, instead of going back to loading.
  const [held, setHeld] = useState<ReadonlyMap<number, PreviewRequest>>(
    () => new Map()
  );
  const previewRequests = useMemo(() => {
    const current = previewImages.flatMap(({ key, previewRef }) =>
      failedPreviewKeys.has(key) ? [] : [{ key, previewRef }]
    );
    const keys = new Set(current.map(({ key }) => key));
    const heldOver = previewImages.flatMap(({ key, position }) => {
      const request = held.get(position);
      return request &&
        request.key !== key &&
        !keys.has(request.key) &&
        !failedPreviewKeys.has(request.key)
        ? [request]
        : [];
    });
    return [...current, ...heldOver];
  }, [failedPreviewKeys, held, previewImages]);
  const previews = useLocalFilePreviews(
    previewRequests,
    onPreviewLocalFile,
    nearViewport
  );

  useEffect(() => {
    let next: Map<number, PreviewRequest> | undefined;
    for (const { key, position, previewRef } of previewImages) {
      if (previews.get(key)?.status !== "ready" || held.get(position)?.key === key)
        continue;
      next ??= new Map(held);
      next.set(position, { key, previewRef });
    }
    if (next) setHeld(next);
  }, [held, previewImages, previews]);
  /** The preview a position shows: its own once ready, else the one it showed before. */
  const shownPreview = useCallback(
    (key: string, position: number) => {
      const own = failedPreviewKeys.has(key) ? undefined : previews.get(key);
      if (own?.status === "ready") return own;
      const before = held.get(position);
      return before && !failedPreviewKeys.has(before.key)
        ? previews.get(before.key)
        : undefined;
    },
    [failedPreviewKeys, held, previews]
  );

  const openImageMenu = useContext(MediaMenuContext);
  const groupedPreviews = useMemo(
    () =>
      attachments.flatMap((attachment, position) => {
        if (!showImages || !imagePositions.has(position)) return [];
        const previewImage = previewImages.find((item) => item.position === position);
        if (!previewImage) return [];
        const preview = shownPreview(previewImage.key, position);
        if (preview?.status !== "ready") return [];
        const key = previewImage?.key ?? `${messageId}:${position}`;
        // The whole image, not its preview: what copying and the menu hand over.
        const read = (signal?: AbortSignal) =>
          readAttachmentImage(
            { attachment, call, messageId, previewUrl: preview.url, sourceContext },
            signal
          );
        return [
          {
            image: {
              alt: attachmentLabel(attachment, messagesApi),
              src: preview.url,
              ...(attachment.uploadingId ? { uploading: true } : {}),
              ...(openImageMenu
                ? {
                    onContextMenu: (event) =>
                      openImageMenu(event, {
                        fileName: attachmentLabel(attachment, messagesApi),
                        // An agent's attachment is added to context by reference to its message.
                        ...(sourceContext && attachment.attachmentIndex !== undefined
                          ? {
                              attachment: {
                                groupId: sourceContext.groupId,
                                conversationId: sourceContext.conversationId,
                                messageId,
                                attachmentIndex: attachment.attachmentIndex,
                                fileName: attachmentLabel(attachment, messagesApi),
                                ...(attachment.size !== undefined
                                  ? { size: attachment.size }
                                  : {}),
                              },
                            }
                          : {}),
                        resolve: read,
                      }),
                  }
                : {}),
            } satisfies ChatPanelImageGroupImage,
            key,
            position,
            read,
          },
        ];
      }),
    [
      attachments,
      call,
      openImageMenu,
      sourceContext,
      imagePositions,
      messageId,
      messagesApi,
      previewImages,
      shownPreview,
      showImages,
    ]
  );
  const groupedImages = groupedPreviews.map(({ image }) => image);
  // Reveal the initial group together so staggered loads do not resize it
  // card by card. Once ready, its leases remain with this mounted message.
  // A position still showing its image before is not waiting for anything.
  const currentRequests = previewImages.flatMap(({ key, position }) =>
    failedPreviewKeys.has(key) ? [] : [{ key, position }]
  );
  const pendingPreviewKeys = currentRequests.flatMap(({ key, position }) => {
    const status = previews.get(key)?.status;
    return status === "ready" ||
      status === "unavailable" ||
      shownPreview(key, position)?.status === "ready"
      ? []
      : [key];
  });

  // A loader's "unavailable" is terminal for this message; recording it here
  // keeps the fallback card in place instead of re-requesting on re-entry.
  const unavailableKeys = currentRequests.flatMap(({ key }) =>
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
