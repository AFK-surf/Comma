/**
 * Passages the reader picked out of the thread and staged for the next
 * message. Quotes are renderer-only draft state: unlike attachments they need
 * no intake, so they never enter the Main-owned draft epoch and are folded
 * into the message text at send time.
 */
export type ChatDraftQuote = {
  id: string;
  text: string;
};

/** Longest single-line preview used for a quote chip's accessible name. */
const QUOTE_LABEL_LIMIT = 80;

let quoteSequence = 0;

export function createChatDraftQuote(text: string): ChatDraftQuote {
  quoteSequence += 1;
  return { id: `quote-${quoteSequence}`, text };
}

export function chatQuoteLabel(text: string) {
  const collapsed = text.replace(/\s+/gu, " ").trim();
  return collapsed.length > QUOTE_LABEL_LIMIT
    ? `${collapsed.slice(0, QUOTE_LABEL_LIMIT)}…`
    : collapsed;
}
