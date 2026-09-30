import { formatNumber, type CommaLocale } from "@comma/i18n";
import type { useCommaMessages } from "@comma/i18n/react";
import type { ChatAttachment } from "../../model/conversationChannel";

export function attachmentLabel(
  attachment: ChatAttachment,
  messagesApi: ReturnType<typeof useCommaMessages>
) {
  return (
    attachment.fileName ??
    attachment.title ??
    (attachment.blockType === "image"
      ? messagesApi.chat_attachment_image()
      : messagesApi.chat_attachment_file())
  );
}

export function formatAttachmentSize(size: number | undefined, locale: CommaLocale) {
  if (size === undefined || !Number.isFinite(size) || size < 0) {
    return undefined;
  }

  if (size < 1024) {
    return `${formatNumber(size, locale, { maximumFractionDigits: 0 })} B`;
  }

  if (size < 1024 * 1024) {
    return `${formatNumber(size / 1024, locale, { maximumFractionDigits: 0 })} KB`;
  }

  return `${formatNumber(size / (1024 * 1024), locale, {
    maximumFractionDigits: 1,
  })} MB`;
}
