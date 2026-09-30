import { useCommaMessages } from "@comma/i18n/react";
import { HoverCard } from "../../hover-card";
import { CloseQuoteIcon, FileIcon } from "../../icons";
import { cx } from "../../utils";
import {
  aiInputAttachment,
  aiInputQuoteAttachment,
  aiInputQuoteHoverCard,
  aiInputQuotePreview,
  aiInputQuotePreviewText,
  aiInputQuotePreviewTitle,
} from "../styles";
import {
  AttachmentRemoveButton,
  type AttachmentTileProps,
} from "./AttachmentRemoveButton";
import { ImageAttachment, type ImageAttachmentProps } from "./ImageAttachment";

const FileAttachment = ({ attachment, onRemove }: AttachmentTileProps) => (
  <div
    className={cx(
      aiInputAttachment,
      "flex w-[150px] items-start gap-sm rounded-md border-[0.5px] border-primary bg-popup-primary p-sm"
    )}
    data-slot="file-attachment"
  >
    <div
      className="flex w-9 self-stretch shrink-0 items-center justify-center rounded-xs bg-panel-bg-file text-ai-input-header-text-secondary"
      data-slot="file-icon-surface"
    >
      <FileIcon className="size-5" />
    </div>
    <div className="flex min-w-0 flex-1 flex-col text-xs leading-[18px]">
      <span className="truncate text-ai-input-panel-text-attachment-primary">
        {attachment.name}
      </span>
      {attachment.meta && (
        <span className="truncate text-ai-input-panel-text-attachment-secondary">
          {attachment.meta}
        </span>
      )}
    </div>
    <AttachmentRemoveButton attachment={attachment} onRemove={onRemove} />
  </div>
);

/**
 * A quoted passage staged for the next message. The tile itself is the hover
 * trigger — React Aria makes it focusable so the full text is reachable by
 * keyboard too, not just by pointer.
 */
const QuoteAttachment = ({ attachment, onRemove }: AttachmentTileProps) => {
  const messages = useCommaMessages();
  const detail = attachment.detail ?? attachment.name;

  return (
    <div className={cx(aiInputAttachment, "size-12")} data-slot="quote-attachment">
      <HoverCard
        className={aiInputQuoteHoverCard}
        content={
          <div className={aiInputQuotePreview}>
            <strong className={aiInputQuotePreviewTitle}>
              {messages.ui_ai_quoted_text()}
            </strong>
            <p className={aiInputQuotePreviewText}>{detail}</p>
          </div>
        }
        placement="top start"
      >
        <button
          aria-label={messages.ui_ai_quoted_text_named({ text: attachment.name })}
          className={aiInputQuoteAttachment}
          type="button"
        >
          <CloseQuoteIcon className="size-5" />
        </button>
      </HoverCard>
      <AttachmentRemoveButton attachment={attachment} onRemove={onRemove} />
    </div>
  );
};

export const AttachmentChip = ({
  attachment,
  onPreview,
  onRemove,
}: ImageAttachmentProps) =>
  attachment.type === "quote" ? (
    <QuoteAttachment attachment={attachment} onRemove={onRemove} />
  ) : attachment.type === "image" ? (
    <ImageAttachment
      attachment={attachment}
      onPreview={onPreview}
      onRemove={onRemove}
    />
  ) : (
    <FileAttachment attachment={attachment} onRemove={onRemove} />
  );
