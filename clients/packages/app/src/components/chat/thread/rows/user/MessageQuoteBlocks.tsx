import { useCommaMessages } from "@comma/i18n/react";
import {
  aiInputQuoteAttachment,
  aiInputQuoteHoverCard,
  aiInputQuotePreview,
  aiInputQuotePreviewText,
  aiInputQuotePreviewTitle,
  CloseQuoteIcon,
  HoverCard,
} from "@comma/ui";

/**
 * Passages the sender quoted from the thread. Each one is the same icon-only
 * tile as the composer's staged quote chip — the text shows in the identical
 * hover card, and the tile's label carries it for screen readers and keyboard
 * focus.
 */
export function MessageQuoteBlocks({
  messageId,
  quotes,
}: {
  messageId: string;
  quotes: readonly string[];
}) {
  const messagesApi = useCommaMessages();
  if (quotes.length === 0) return null;

  return (
    <>
      {quotes.map((quote, index) => (
        <div
          className="comma-chat-message-quote"
          data-testid="chat-message-quote"
          // Two identical quotes in one message are legitimate, so the
          // position is part of the identity.
          key={`${messageId}:quote:${index}`}
        >
          <HoverCard
            className={aiInputQuoteHoverCard}
            content={
              <div className={aiInputQuotePreview}>
                <strong className={aiInputQuotePreviewTitle}>
                  {messagesApi.ui_ai_quoted_text()}
                </strong>
                <p className={aiInputQuotePreviewText}>{quote}</p>
              </div>
            }
            placement="top start"
          >
            <button
              aria-label={messagesApi.ui_ai_quoted_text_named({ text: quote })}
              className={aiInputQuoteAttachment}
              type="button"
            >
              <CloseQuoteIcon className="size-5" />
            </button>
          </HoverCard>
        </div>
      ))}
    </>
  );
}
