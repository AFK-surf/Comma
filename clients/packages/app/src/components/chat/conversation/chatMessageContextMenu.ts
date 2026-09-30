import { parseAttachmentsBlock, parseQuotedTextBlock } from "../model/protocol";
import { stripBrowserElementInspectionContext } from "../../chat-sidebar/browserElementInspection";

const CHAT_MESSAGE_ARTICLE_SELECTOR = [
  'article[data-slot="chat-assistant-output"]',
  "article.comma-chat-message-assistant",
  'article[data-slot="chat-user-output"]',
  "article.comma-chat-message-user",
].join(", ");
/**
 * Trailing furniture inside a message article. It is real text in the DOM but
 * not part of what the reader sees as the message, so a quote must stop before
 * it.
 */
const CHAT_MESSAGE_CHROME_SELECTOR = [
  ".comma-chat-block-extras",
  ".comma-chat-message-actions",
  ".comma-chat-failed-row",
  ".comma-chat-user-bubble-toggle-row",
].join(", ");
const CHAT_MESSAGE_INTERACTIVE_SELECTOR = [
  ".comma-inline-task",
  "a[href]",
  "button",
  "input",
  "select",
  "textarea",
  '[contenteditable="true"]',
  ".comma-chat-message-actions",
  ".comma-chat-block-extras",
].join(", ");

function eventTargetElement(target: EventTarget | null): Element | null {
  if (target instanceof Element) return target;
  if (target instanceof Node) return target.parentElement;
  return null;
}

export function resolveChatMessageArticleFromEventTarget(
  target: EventTarget | null,
  root: Element
): HTMLElement | null {
  const element = eventTargetElement(target);
  const article = element?.closest<HTMLElement>(CHAT_MESSAGE_ARTICLE_SELECTOR);
  if (!article || !root.contains(article)) return null;
  return article;
}

export function isInteractiveChatMessageTarget(
  target: EventTarget | null,
  article: Element
): boolean {
  const element = eventTargetElement(target);
  const interactive = element?.closest<HTMLElement>(CHAT_MESSAGE_INTERACTIVE_SELECTOR);
  return Boolean(interactive && article.contains(interactive));
}

export function selectedTextInRoot(root: Element): string {
  if (typeof window === "undefined") return "";
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return "";
  const range = selection.getRangeAt(0);
  const ancestor = range.commonAncestorContainer;
  const ancestorElement =
    ancestor instanceof Element ? ancestor : ancestor.parentElement;
  if (!ancestorElement || !root.contains(ancestorElement)) return "";
  return selection.toString();
}

export type ChatSelectionAnchor = {
  bottom: number;
  left: number;
  right: number;
  top: number;
};

/**
 * Which way the selection was drawn. "forward" is anchor-before-focus — a
 * left-to-right, top-to-bottom sweep — and "backward" is the reverse. "none"
 * is for selections with no travel to speak of, such as a double-click.
 */
export type ChatSelectionDirection = "forward" | "backward" | "none";

export type ChatSelectionQuote = {
  anchor: ChatSelectionAnchor;
  direction: ChatSelectionDirection;
  text: string;
};

/**
 * The DOM records where a selection started (anchor) and where it ended
 * (focus) separately, which is the only reliable trace of the gesture's
 * direction once the pointer is up.
 */
function selectionDirection(selection: Selection): ChatSelectionDirection {
  const { anchorNode, anchorOffset, focusNode, focusOffset } = selection;
  if (!anchorNode || !focusNode) return "none";

  if (anchorNode === focusNode) {
    if (anchorOffset === focusOffset) return "none";
    return anchorOffset < focusOffset ? "forward" : "backward";
  }

  const position = anchorNode.compareDocumentPosition(focusNode);
  if (position & Node.DOCUMENT_POSITION_FOLLOWING) return "forward";
  if (position & Node.DOCUMENT_POSITION_PRECEDING) return "backward";
  return "none";
}

/**
 * The live selection, but only when it sits wholly inside one chat message's
 * body. Interactive regions are excluded on the same terms as the copy menu,
 * so quoting never picks up chrome the reader did not mean to quote.
 */
function closestChatMessageArticle(node: Node | null): HTMLElement | null {
  const element = node instanceof Element ? node : node?.parentElement;
  return element?.closest<HTMLElement>(CHAT_MESSAGE_ARTICLE_SELECTOR) ?? null;
}

/**
 * The message a selection belongs to, preferring where it begins in document
 * order. Reading this from the range's ends rather than its common ancestor is
 * what lets an overshooting drag still resolve: the moment a selection spills
 * past the article, the common ancestor climbs above it and matches nothing.
 */
function chatMessageArticleForRange(range: Range): HTMLElement | null {
  return (
    closestChatMessageArticle(range.startContainer) ??
    closestChatMessageArticle(range.endContainer)
  );
}

/**
 * The part of a message that is worth quoting: its body, stopping at the first
 * piece of chrome. Ref cards, attachment pills, the copy row and the
 * expand chevron all carry text that the reader never perceives as part of the
 * message, and a selection that runs past the last line swallows all of it.
 */
function quotableBounds(article: Element): Range {
  const bounds = article.ownerDocument.createRange();
  bounds.selectNodeContents(article);
  const chrome = article.querySelector(CHAT_MESSAGE_CHROME_SELECTOR);
  if (chrome?.parentNode) bounds.setEndBefore(chrome);
  return bounds;
}

/**
 * Pull a selection that ran past the message body back inside it.
 *
 * Dragging below the last line keeps selecting — through the message's own ref
 * cards and action row, the next message, the empty space after the thread —
 * and none of that reads as highlighted text, so the reader has no way to tell
 * what they actually caught. Clamping the live selection (rather than quietly
 * quoting a subset) puts the answer back on screen: the highlight ends exactly
 * where the quote will.
 */
function clampSelectionToQuotableBody(
  selection: Selection,
  range: Range,
  article: Element,
  backward: boolean
) {
  const bounds = quotableBounds(article);
  const startsBefore = range.compareBoundaryPoints(Range.START_TO_START, bounds) < 0;
  const endsAfter = range.compareBoundaryPoints(Range.END_TO_END, bounds) > 0;
  if (!startsBefore && !endsAfter) return range;

  const clamped = range.cloneRange();
  if (startsBefore) clamped.setStart(bounds.startContainer, bounds.startOffset);
  if (endsAfter) clamped.setEnd(bounds.endContainer, bounds.endOffset);
  if (clamped.collapsed) return range;

  // Re-apply with the original orientation so the entrance still reads as
  // continuing the gesture the reader made.
  if (backward) {
    selection.setBaseAndExtent(
      clamped.endContainer,
      clamped.endOffset,
      clamped.startContainer,
      clamped.startOffset
    );
  } else {
    selection.setBaseAndExtent(
      clamped.startContainer,
      clamped.startOffset,
      clamped.endContainer,
      clamped.endOffset
    );
  }

  return selection.rangeCount > 0 ? selection.getRangeAt(0) : clamped;
}

export function resolveChatSelectionQuote(root: Element): ChatSelectionQuote | null {
  if (typeof window === "undefined") return null;
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;

  const article = chatMessageArticleForRange(selection.getRangeAt(0));
  if (!article || !root.contains(article)) return null;

  // Direction comes from the gesture as drawn, before any clamping moves the
  // selection's ends around.
  const direction = selectionDirection(selection);
  const range = clampSelectionToQuotableBody(
    selection,
    selection.getRangeAt(0),
    article,
    direction === "backward"
  );

  const text = selection.toString().trim();
  if (!text) return null;

  const ancestor = range.commonAncestorContainer;
  const element = ancestor instanceof Element ? ancestor : ancestor.parentElement;
  if (isInteractiveChatMessageTarget(element, article)) return null;

  const rect = range.getBoundingClientRect();
  // A range inside a collapsed or unrendered subtree measures as an empty box
  // at the origin; anchoring to that would park the bar in the corner.
  if (rect.width === 0 && rect.height === 0) return null;

  return {
    anchor: {
      bottom: rect.bottom,
      left: rect.left,
      right: rect.right,
      top: rect.top,
    },
    direction,
    text,
  };
}

function isUserMessageArticle(article: HTMLElement) {
  return (
    article.dataset.slot === "chat-user-output" ||
    article.classList.contains("comma-chat-message-user")
  );
}

export function resolveChatMessageText(
  article: HTMLElement,
  messages: readonly { messageId: string; text: string }[],
  assistantDraft?: { responseKey: string; text: string } | undefined
): string {
  const messageId = article.dataset.messageId;
  if (messageId) {
    const message = messages.find((item) => item.messageId === messageId);
    if (message) {
      return isUserMessageArticle(article)
        ? parseQuotedTextBlock(
            parseAttachmentsBlock(stripBrowserElementInspectionContext(message.text))
              .body
          ).body
        : message.text;
    }
  }

  if (isUserMessageArticle(article)) return "";

  const responseKey = article.dataset.responseKey;
  if (
    assistantDraft &&
    (responseKey === undefined || responseKey === assistantDraft.responseKey)
  ) {
    return assistantDraft.text;
  }

  return "";
}

export function resolveChatMessageCopyText(
  article: HTMLElement,
  messages: readonly { messageId: string; text: string }[],
  assistantDraft?: { responseKey: string; text: string } | undefined
): string {
  const selectedText = selectedTextInRoot(article);
  if (selectedText) return selectedText;
  return resolveChatMessageText(article, messages, assistantDraft);
}
