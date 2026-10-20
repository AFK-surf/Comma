import type { AttachedText } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import {
  aiInputQuoteHoverCard,
  aiInputQuotePreview,
  aiInputQuotePreviewText,
  aiInputQuotePreviewTitle,
} from "@comma/ui/components/ai-input";
import { HoverCard } from "@comma/ui/components/hover-card";
import { FileTextIcon } from "@comma/ui/components/icons";
import { resolveProviderBrandLogo } from "@comma/ui/components/provider-brand-logos";
import { chatSnippetTitle } from "../../../composer/draftSnippets";

/**
 * Text the sender attached as a block, such as a Routine item. Each one is a
 * one-line pill with the mark of the app it came from and its first line; the
 * whole text shows on hover the way a quote's does.
 */
export function MessageAttachedTexts({
  messageId,
  texts,
}: {
  messageId: string;
  texts: readonly AttachedText[];
}) {
  const messagesApi = useCommaMessages();
  if (texts.length === 0) return null;

  return (
    <div className="comma-chat-block-extras" data-placement="leading">
      {texts.map((attached, index) => {
        const title = chatSnippetTitle(attached.text);
        const BrandLogo = resolveProviderBrandLogo(attached.source);
        return (
          <HoverCard
            className={aiInputQuoteHoverCard}
            content={
              <div className={aiInputQuotePreview}>
                <strong className={aiInputQuotePreviewTitle}>
                  {attached.source ?? messagesApi.chat_attached_text()}
                </strong>
                <p className={aiInputQuotePreviewText}>{attached.text}</p>
              </div>
            }
            // Two identical texts in one message are legitimate, so the
            // position is part of the identity.
            key={`${messageId}:text:${index}`}
            placement="top start"
          >
            <button
              aria-label={title}
              className="comma-chat-attached-text"
              data-no-press-feedback
              data-testid={`chat-attached-text-${messageId}-${index}`}
              type="button"
            >
              <span aria-hidden className="comma-chat-attached-text-icon">
                {BrandLogo ? <BrandLogo /> : <FileTextIcon />}
              </span>
              <span className="comma-chat-attached-text-title">{title}</span>
            </button>
          </HoverCard>
        );
      })}
    </div>
  );
}
