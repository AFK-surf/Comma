import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { ChatPanelFile, ChatPanelImage, ChatPanelImageGroup } from "@comma/ui";
import { useContext, useState } from "react";
import type {
  ChatAttachment,
  ChatImagePreviewRef,
  LocalFilePreview,
} from "../../model/conversationChannel";
import { MessageInlineVideo } from "../inline/MessageInlineVideo";
import { ThreadFileSourceContext } from "../threadContexts";
import { AttachmentPill } from "./AttachmentPill";
import { attachmentLabel, formatAttachmentSize } from "./attachmentLabels";
import { ChatImageGroupPlaceholder } from "./images/ChatImageGroupPlaceholder";
import { useImageGroupReveal } from "./images/useImageGroupReveal";
import { useImagePreviews } from "./images/useImagePreviews";
import { useImagePreviewTargets } from "./images/useImagePreviewTargets";
import { useAttachmentFileActions } from "./useAttachmentFileActions";
import { useInlineVideos } from "./useInlineVideos";
import { useNearViewportActivation } from "./useNearViewportActivation";

export function MessageAttachments({
  attachments,
  messageId,
  onPreviewLocalFile,
  section = "all",
}: {
  attachments: ChatAttachment[];
  messageId: string;
  onPreviewLocalFile?:
    | ((previewRef: ChatImagePreviewRef) => Promise<LocalFilePreview | undefined>)
    | undefined;
  /**
   * Which attachment kinds this instance renders. The full list always comes
   * in so `position`-derived keys and testids stay stable across sections.
   */
  section?: "all" | "files" | "images" | undefined;
}) {
  const locale = useCommaLocale();
  const messagesApi = useCommaMessages();
  const showImages = section !== "files";
  // Only an agent's message paints in the undivided section. There, a file
  // block the inline-media allowlist admits joins the image group or plays in
  // place; a user's own files keep their pills.
  const inlineMediaSection = section === "all";
  const sourceContext = useContext(ThreadFileSourceContext);
  // The mounted message owns the deck and its loaded images. Scrolling only
  // gates unfinished acquisitions; it must not reset the presentation.
  const [imageGroupExpanded, setImageGroupExpanded] = useState(false);
  const targets = useImagePreviewTargets({
    attachments,
    inlineMediaSection,
    messageId,
    onPreviewLocalFile,
    showImages,
  });
  const { handleVideoUnavailable, inlineVideos } = useInlineVideos(
    attachments,
    inlineMediaSection,
    sourceContext
  );
  const { imageGroupActivated, nearViewport, previewElementRef } =
    useNearViewportActivation(targets.previewImages, inlineVideos);
  const images = useImagePreviews({
    attachments,
    messageId,
    nearViewport,
    onPreviewLocalFile,
    showImages,
    sourceContext,
    targets,
  });
  const { groupedImages, groupedPreviews, handlePreviewImageError } = images;
  const { imageGroupSettled, placeholderImageCount, unavailableImageAttachments } =
    useImageGroupReveal({ attachments, images, showImages, targets });
  const nonImageAttachments =
    section === "images"
      ? []
      : attachments.flatMap((attachment, position) =>
          targets.imagePositions.has(position) ||
          inlineVideos.some((video) => video.position === position)
            ? []
            : [{ attachment, position }]
        );
  const showFileCards = section === "all";
  const fileAttachments = showFileCards
    ? [...nonImageAttachments, ...unavailableImageAttachments]
    : section === "images"
      ? unavailableImageAttachments
      : [];
  const pillAttachments = showFileCards ? [] : nonImageAttachments;
  const { beginAttempt, fileActions, fileSources } = useAttachmentFileActions(
    attachments,
    messageId,
    sourceContext
  );

  return (
    <div
      aria-label={messagesApi.chat_attachments_label()}
      className="comma-chat-attachments"
      onErrorCapture={handlePreviewImageError}
      ref={previewElementRef}
    >
      {imageGroupActivated && imageGroupSettled ? (
        groupedImages.length > 0 ? (
          inlineMediaSection ? (
            // An agent's image keeps the ratio it was produced at: the frame
            // only bounds how large it may paint, so the whole picture stays
            // visible instead of a cropped fixed-ratio card.
            <div className="comma-chat-inline-images">
              {groupedPreviews.map(({ image, key }) => (
                <ChatPanelImage
                  alt={image.alt}
                  className="comma-chat-inline-image"
                  {...(image.onContextMenu
                    ? { onContextMenu: image.onContextMenu }
                    : {})}
                  key={key}
                  src={image.src}
                />
              ))}
            </div>
          ) : (
            <ChatPanelImageGroup
              defaultExpanded={imageGroupExpanded}
              images={groupedImages}
              onExpandedChange={setImageGroupExpanded}
            />
          )
        ) : null
      ) : placeholderImageCount > 0 ? (
        <ChatImageGroupPlaceholder
          count={placeholderImageCount}
          expanded={imageGroupExpanded}
        />
      ) : null}
      {sourceContext
        ? inlineVideos.flatMap(({ mediaType, position }) => {
            const source = fileSources.get(position);
            return source
              ? [
                  <MessageInlineVideo
                    active={imageGroupActivated}
                    api={sourceContext.api}
                    beginAttempt={beginAttempt}
                    key={`video:${position}`}
                    mediaType={mediaType}
                    onUnavailable={handleVideoUnavailable}
                    position={position}
                    source={source}
                    testId={`chat-attachment-video-${messageId}-${position}`}
                  />,
                ]
              : [];
          })
        : null}
      {fileAttachments.length > 0 ? (
        <div className="comma-chat-file-card-column">
          {fileAttachments.map(({ attachment, position }) => {
            const label = attachmentLabel(attachment, messagesApi);
            return (
              <ChatPanelFile
                fileName={label}
                {...(fileActions.get(position)?.onPreview
                  ? { onPreview: fileActions.get(position)!.onPreview! }
                  : {})}
                {...(fileActions.get(position)?.openIn
                  ? { openIn: fileActions.get(position)!.openIn! }
                  : {})}
                key={`${attachment.blockType}:${label}:${position}`}
                testId={`chat-attachment-file-${messageId}-${position}`}
                {...(attachment.mimeType ? { mimeType: attachment.mimeType } : {})}
                {...(attachment.size === undefined
                  ? {}
                  : { fileSize: attachment.size })}
              />
            );
          })}
        </div>
      ) : null}
      {pillAttachments.length > 0 ? (
        <div className="comma-chat-attachment-row">
          {pillAttachments.map(({ attachment, position }) => {
            const label = attachmentLabel(attachment, messagesApi);
            return (
              <AttachmentPill
                key={`${attachment.blockType}:${label}:${position}`}
                label={label}
                messageId={messageId}
                position={position}
                size={formatAttachmentSize(attachment.size, locale)}
              />
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
