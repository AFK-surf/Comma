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
  messages: readonly {
    messageId: string;
    text: string;
    display?: { body: string } | undefined;
  }[],
  assistantDraft?: { responseKey: string; text: string } | undefined
): string {
  const messageId = article.dataset.messageId;
  if (messageId) {
    const message = messages.find((item) => item.messageId === messageId);
    if (message) {
      return isUserMessageArticle(article)
        ? (message.display?.body ?? message.text)
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

export type ChatSelectionShareJoin = "inline" | "inline-space" | "paragraph";

export type ChatSelectionSharePayload = {
  selectedText: string;
  beforeContext: string;
  afterContext: string;
  beforeJoin: ChatSelectionShareJoin;
  afterJoin: ChatSelectionShareJoin;
  authorRole: "assistant" | "user";
};

const SHARE_BLOCK_TAG_NAMES = new Set([
  "ADDRESS",
  "ARTICLE",
  "ASIDE",
  "BLOCKQUOTE",
  "DD",
  "DIV",
  "DL",
  "DT",
  "FIGCAPTION",
  "FIGURE",
  "FOOTER",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HEADER",
  "LI",
  "MAIN",
  "NAV",
  "OL",
  "P",
  "PRE",
  "SECTION",
  "TR",
  "UL",
]);

function closestShareBlock(node: Node, stopAt: Element): Element {
  let current: Element | null = node instanceof Element ? node : node.parentElement;
  while (current && current !== stopAt) {
    if (SHARE_BLOCK_TAG_NAMES.has(current.tagName)) return current;
    current = current.parentElement;
  }
  return stopAt;
}

function isInsideChatMessageChrome(node: Node, article: Element): boolean {
  const element = node instanceof Element ? node : node.parentElement;
  const chrome = element?.closest(CHAT_MESSAGE_CHROME_SELECTOR);
  return Boolean(chrome && article.contains(chrome));
}

function normalizeExtractedText(raw: string): string {
  return raw
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t\f\v]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n");
}

/**
 * Extracts the selected text inside a chat message along with the surrounding
 * text before and after the selection in the same message, preserving exact
 * inline vs paragraph boundaries for share-image rendering.
 */
export function resolveChatMessageSelectionShare(
  article: HTMLElement
): ChatSelectionSharePayload | null {
  if (typeof window === "undefined") return null;
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;

  const liveRange = selection.getRangeAt(0);
  const bounds = quotableBounds(article);

  // Reject selections that do not intersect this article's quotable body.
  // Note W3C DOM Range order: START_TO_END compares this.end to source.start;
  // END_TO_START compares this.start to source.end.
  if (
    liveRange.compareBoundaryPoints(Range.START_TO_END, bounds) <= 0 ||
    liveRange.compareBoundaryPoints(Range.END_TO_START, bounds) >= 0
  ) {
    return null;
  }

  const clamped = liveRange.cloneRange();
  if (clamped.compareBoundaryPoints(Range.START_TO_START, bounds) < 0) {
    clamped.setStart(bounds.startContainer, bounds.startOffset);
  }
  if (clamped.compareBoundaryPoints(Range.END_TO_END, bounds) > 0) {
    clamped.setEnd(bounds.endContainer, bounds.endOffset);
  }
  if (clamped.collapsed) return null;

  const doc = article.ownerDocument;
  const probe = doc.createRange();
  const walker = doc.createTreeWalker(
    article,
    NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT
  );

  let before = "";
  let selected = "";
  let after = "";
  let lastBlockBefore: Element | null = null;
  let lastBlockSelected: Element | null = null;
  let lastBlockAfter: Element | null = null;
  let firstSelectedBlock: Element | null = null;
  let lastBeforeNonEmptyBlock: Element | null = null;
  let firstAfterNonEmptyBlock: Element | null = null;
  let sawBrBeforeSelected = false;
  let sawBrAfterSelected = false;
  let pendingBr = false;

  const appendBucket = (
    bucket: "before" | "selected" | "after",
    chunk: string,
    block: Element
  ) => {
    if (!chunk) return;
    const hasVisible = chunk.trim().length > 0;
    if (bucket === "before") {
      if (before && hasVisible) {
        if (lastBlockBefore && lastBlockBefore !== block) before += "\n\n";
        else if (pendingBr) before += "\n";
      }
      before += chunk;
      if (hasVisible) {
        lastBlockBefore = block;
        lastBeforeNonEmptyBlock = block;
        pendingBr = false;
        sawBrBeforeSelected = false;
      }
      return;
    }
    if (bucket === "selected") {
      if (selected && hasVisible) {
        if (lastBlockSelected && lastBlockSelected !== block) selected += "\n\n";
        else if (pendingBr) selected += "\n";
      } else if (!selected && hasVisible) {
        firstSelectedBlock = block;
        if (pendingBr) sawBrBeforeSelected = true;
      }
      selected += chunk;
      if (hasVisible) {
        lastBlockSelected = block;
        pendingBr = false;
        sawBrAfterSelected = false;
      }
      return;
    }
    if (after && hasVisible) {
      if (lastBlockAfter && lastBlockAfter !== block) after += "\n\n";
      else if (pendingBr) after += "\n";
    } else if (!after && hasVisible) {
      firstAfterNonEmptyBlock = block;
      if (pendingBr) sawBrAfterSelected = true;
    }
    after += chunk;
    if (hasVisible) {
      lastBlockAfter = block;
      pendingBr = false;
    }
  };

  let current = walker.nextNode();
  while (current) {
    if (isInsideChatMessageChrome(current, article)) {
      current = walker.nextNode();
      continue;
    }
    if (current.nodeType === Node.ELEMENT_NODE) {
      if ((current as Element).tagName === "BR") {
        pendingBr = true;
      }
      current = walker.nextNode();
      continue;
    }
    if (current.nodeType === Node.TEXT_NODE) {
      const textNode = current as Text;
      const data = textNode.data;
      const len = data.length;
      if (len === 0) {
        current = walker.nextNode();
        continue;
      }

      // Check whether this text node lies inside quotable bounds.
      probe.setStart(textNode, 0);
      probe.collapse(true);
      if (probe.compareBoundaryPoints(Range.END_TO_START, bounds) >= 0) {
        break;
      }

      let startPos: number;
      if (textNode === clamped.startContainer) {
        startPos = Math.min(Math.max(clamped.startOffset, 0), len);
      } else {
        startPos =
          probe.compareBoundaryPoints(Range.START_TO_START, clamped) < 0 ? len : 0;
      }

      let endPos: number;
      if (textNode === clamped.endContainer) {
        endPos = Math.min(Math.max(clamped.endOffset, 0), len);
      } else {
        endPos = probe.compareBoundaryPoints(Range.END_TO_START, clamped) < 0 ? len : 0;
      }

      const clampedEnd = Math.max(startPos, endPos);
      const block = closestShareBlock(textNode, article);

      appendBucket("before", data.slice(0, startPos), block);
      appendBucket("selected", data.slice(startPos, clampedEnd), block);
      appendBucket("after", data.slice(clampedEnd), block);
    }
    current = walker.nextNode();
  }

  const rawSelected = normalizeExtractedText(selected);
  const normalizedSelected = rawSelected.trim();
  if (!normalizedSelected) return null;

  const rawBefore = normalizeExtractedText(before);
  const rawAfter = normalizeExtractedText(after);
  const beforeEndedWithNewline = /\n\s*$/.test(rawBefore);
  const afterStartedWithNewline = /^\s*\n/.test(rawAfter);
  const beforeHasInlineSpace = /[ \t]$/.test(rawBefore) || /^[ \t]/.test(rawSelected);
  const afterHasInlineSpace = /[ \t]$/.test(rawSelected) || /^[ \t]/.test(rawAfter);

  const normalizedBefore = rawBefore.trim();
  const normalizedAfter = rawAfter.trim();

  const beforeJoin: ChatSelectionShareJoin =
    !normalizedBefore ||
    beforeEndedWithNewline ||
    sawBrBeforeSelected ||
    (lastBeforeNonEmptyBlock !== null &&
      firstSelectedBlock !== null &&
      lastBeforeNonEmptyBlock !== firstSelectedBlock)
      ? "paragraph"
      : beforeHasInlineSpace
        ? "inline-space"
        : "inline";

  const afterJoin: ChatSelectionShareJoin =
    !normalizedAfter ||
    afterStartedWithNewline ||
    sawBrAfterSelected ||
    (lastBlockSelected !== null &&
      firstAfterNonEmptyBlock !== null &&
      lastBlockSelected !== firstAfterNonEmptyBlock)
      ? "paragraph"
      : afterHasInlineSpace
        ? "inline-space"
        : "inline";

  return {
    selectedText: normalizedSelected,
    beforeContext: normalizedBefore,
    afterContext: normalizedAfter,
    beforeJoin,
    afterJoin,
    authorRole: isUserMessageArticle(article) ? "user" : "assistant",
  };
}

export type ShareSourceTitleSnapshot = {
  kind?: string | null | undefined;
  title?: string | null | undefined;
  updated_at?: number | null | undefined;
};

/**
 * Resolves the title shown on a share card. Only Comma Tasks (`agent_task`)
 * display a source title; Router / Home chats (`user_chat`) intentionally leave
 * the title slot empty. For a Task, prefers the fresher Task summary title when
 * it is at least as recent as the conversation detail snapshot.
 */
export function resolveShareSourceTitle(
  conversation: ShareSourceTitleSnapshot | null | undefined,
  taskSummary: ShareSourceTitleSnapshot | null | undefined
): string {
  const presentation = conversation ?? taskSummary;
  if (presentation?.kind !== "agent_task") return "";
  const taskSummaryIsNewer =
    taskSummary != null &&
    (taskSummary.updated_at ?? 0) >= (conversation?.updated_at ?? 0);
  return ((taskSummaryIsNewer && taskSummary.title) || presentation.title || "").trim();
}
