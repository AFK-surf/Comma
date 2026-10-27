import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { HoverCard } from "../../hover-card";
import { ChevronRightSmallIcon, FileIcon, FileTextIcon } from "../../icons";
import { cx } from "../../utils";
import {
  aiInputAttachment,
  aiInputFileAttachment,
  aiInputFileFooter,
  aiInputFileIconSurface,
  aiInputFileMeta,
  aiInputFileName,
  aiInputQuoteAttachment,
  aiInputQuoteExcerpt,
  aiInputQuoteHoverCard,
  aiInputQuotePreview,
  aiInputQuotePreviewText,
  aiInputQuotePreviewTitle,
  aiInputSnippetAttachment,
  aiInputSnippetExpand,
  aiInputSnippetIconSurface,
  aiInputSnippetTitle,
} from "../styles";
import {
  AttachmentRemoveButton,
  type AttachmentTileProps,
} from "./AttachmentRemoveButton";
import { ImageAttachment, type ImageAttachmentProps } from "./ImageAttachment";

const FileAttachment = ({ attachment, onRemove }: AttachmentTileProps) => (
  <div
    className={cx(aiInputAttachment, aiInputFileAttachment)}
    data-slot="file-attachment"
  >
    <span className={aiInputFileName} data-slot="file-name">
      {attachment.name}
    </span>
    <div className={aiInputFileFooter}>
      <div className={aiInputFileIconSurface} data-slot="file-icon-surface">
        <FileIcon />
      </div>
      {attachment.meta && <span className={aiInputFileMeta}>{attachment.meta}</span>}
    </div>
    <AttachmentRemoveButton attachment={attachment} onRemove={onRemove} />
  </div>
);

/**
 * A quoted passage staged for the next message. The tile shows the passage's
 * opening lines and is itself the hover trigger for the whole text — React
 * Aria makes it focusable so that text is reachable by keyboard too.
 */
const QuoteAttachment = ({ attachment, onRemove }: AttachmentTileProps) => {
  const messages = useCommaMessages();
  const detail = attachment.detail ?? attachment.name;

  return (
    <div className={aiInputAttachment} data-slot="quote-attachment">
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
          <span aria-hidden className={aiInputQuoteExcerpt}>
            {detail}
          </span>
        </button>
      </HoverCard>
      <AttachmentRemoveButton attachment={attachment} onRemove={onRemove} />
    </div>
  );
};

/**
 * A block of text staged for the next message in place of the prompt, such as
 * a Routine row. "Show in text field" hands the text to the prompt, where it
 * can be edited, and the tile goes away.
 */
const SnippetAttachment = ({ attachment, onRemove }: AttachmentTileProps) => {
  const messages = useCommaMessages();

  return (
    <div
      className={cx(aiInputAttachment, aiInputSnippetAttachment)}
      data-slot="snippet-attachment"
    >
      {/* Like the file chip's name, the title clears the inset close control. */}
      <span className={aiInputSnippetTitle}>{attachment.name}</span>
      <div className="flex min-w-0 items-center gap-sm">
        <div className={aiInputSnippetIconSurface} data-slot="snippet-icon-surface">
          {attachment.icon ?? <FileTextIcon />}
        </div>
        {attachment.onExpand ? (
          <AriaButton
            aria-label={messages.ui_ai_show_in_text_field_named({
              name: attachment.name,
            })}
            className={aiInputSnippetExpand}
            onPress={attachment.onExpand}
          >
            <span className="truncate">{messages.ui_ai_show_in_text_field()}</span>
            <ChevronRightSmallIcon className="size-4 shrink-0" />
          </AriaButton>
        ) : null}
      </div>
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
  ) : attachment.type === "snippet" ? (
    <SnippetAttachment attachment={attachment} onRemove={onRemove} />
  ) : attachment.type === "image" ? (
    <ImageAttachment
      attachment={attachment}
      onPreview={onPreview}
      onRemove={onRemove}
    />
  ) : (
    <FileAttachment attachment={attachment} onRemove={onRemove} />
  );
