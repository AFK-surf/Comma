import type { MouseEvent } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { ImageIcon, LoadingCircleIcon, ReloadIcon } from "../../icons";
import { cx } from "../../utils";
import {
  aiInputAttachment,
  aiInputImageAttachmentError,
  aiInputImageAttachmentErrorLabel,
  aiInputImageAttachmentLoading,
  aiInputImageAttachmentPreviewTrigger,
  aiInputImageAttachmentReady,
} from "../styles";
import {
  AttachmentRemoveButton,
  type AttachmentTileProps,
} from "./AttachmentRemoveButton";

export interface ImageAttachmentProps extends AttachmentTileProps {
  onPreview?: ((event: MouseEvent<HTMLButtonElement>) => void) | undefined;
}

/**
 * An image attachment through its upload. The three states share one 48px
 * tile so the row never reflows as an upload settles, and a failure keeps the
 * remove control alongside the retry so a bad file is never a dead end.
 *
 * A settled tile showing the attachment's own thumbnail is pressable and
 * opens the full-size preview. One whose thumbnail never came (a source the
 * host cannot preview) shows the image glyph instead of a stand-in picture,
 * and has nothing to enlarge, so it stays inert.
 */
export const ImageAttachment = ({
  attachment,
  onPreview,
  onRemove,
}: ImageAttachmentProps) => {
  const messages = useCommaMessages();
  const state = attachment.state ?? "ready";
  const thumbnail = attachment.thumbnailSrc ? (
    <img
      alt={attachment.alt ?? attachment.name}
      className="size-full rounded-md object-cover"
      src={attachment.thumbnailSrc}
    />
  ) : (
    <span className="flex" data-slot="image-attachment-glyph">
      <ImageIcon className="size-5" />
    </span>
  );

  return (
    <div
      className={cx(aiInputAttachment, "size-12")}
      data-slot="image-attachment"
      data-testid="image-attachment"
    >
      {state === "loading" ? (
        <div className={aiInputImageAttachmentLoading} data-state="loading">
          <LoadingCircleIcon className="size-5 animate-spin" />
          <span className="sr-only">
            {messages.ui_ai_uploading_named({ name: attachment.name })}
          </span>
        </div>
      ) : state === "error" ? (
        <AriaButton
          aria-label={messages.ui_ai_upload_retry_named({ name: attachment.name })}
          className={aiInputImageAttachmentError}
          data-state="error"
          onPress={() => attachment.onRetry?.()}
        >
          <ReloadIcon className="size-5" />
          <span className={aiInputImageAttachmentErrorLabel}>
            {messages.ui_ai_upload_retry()}
          </span>
        </AriaButton>
      ) : onPreview && attachment.thumbnailSrc ? (
        <button
          aria-label={messages.ui_ai_preview_attachment({ name: attachment.name })}
          className={aiInputImageAttachmentPreviewTrigger}
          data-state="ready"
          onClick={onPreview}
          type="button"
        >
          {thumbnail}
        </button>
      ) : (
        <div className={aiInputImageAttachmentReady} data-state="ready">
          {thumbnail}
        </div>
      )}
      <AttachmentRemoveButton attachment={attachment} onRemove={onRemove} />
    </div>
  );
};
