import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { ChatPanelFile, ChatPanelImageGroup } from "@comma/ui/components/chat-panel";
import { useContext, useState } from "react";
import type {
  ChatAttachment,
  ChatImagePreviewRef,
  LocalFilePreview,
} from "@comma/core/chat";
import { MessageInlineVideo } from "../inline/MessageInlineVideo";
import { ThreadFileSourceContext } from "../threadContexts";
import { AttachmentPill } from "./AttachmentPill";
import { AttachmentPreviewCard, opensAsPreviewCard } from "./AttachmentPreviewCard";
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
  const { groupedImages, handlePreviewImageError } = images;
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
            <div className="comma-chat-inline-images">
              <ChatPanelImageGroup
                align="start"
                defaultExpanded={imageGroupExpanded}
                images={groupedImages}
                onExpandedChange={setImageGroupExpanded}
              />
            </div>
          ) : (
            <ChatPanelImageGroup
              align="end"
              defaultExpanded={imageGroupExpanded}
              images={groupedImages}
              onExpandedChange={setImageGroupExpanded}
            />
          )
        ) : null
      ) : placeholderImageCount > 0 ? (
        <ChatImageGroupPlaceholder
          align={inlineMediaSection ? "start" : "end"}
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
            const actions = fileActions.get(position);
            const testId = `chat-attachment-file-${messageId}-${position}`;
            // A file the sidebar opens as a page shows its picture and Open; any other is a row.
            if (actions?.onPreview && opensAsPreviewCard(label, attachment.mimeType))
              return (
                <AttachmentPreviewCard
                  fileName={label}
                  key={`${attachment.blockType}:${label}:${position}`}
                  mimeType={attachment.mimeType}
                  onOpen={actions.onPreview}
                  openIn={actions.openIn}
                  size={attachment.size}
                  source={fileSources.get(position)}
                  testId={testId}
                />
              );
            return (
              <ChatPanelFile
                fileName={label}
                {...(actions?.onPreview ? { onPreview: actions.onPreview } : {})}
                {...(actions?.openIn ? { openIn: actions.openIn } : {})}
                key={`${attachment.blockType}:${label}:${position}`}
                testId={testId}
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
                localPath={attachment.localPath}
                messageId={messageId}
                onPreview={fileActions.get(position)?.onPreview}
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
