import type { ChatMessagePart } from "@comma/chat-contract";

/**
 * Inline mention wire format for outgoing user messages.
 *
 * A mention travels inside the plain message text as a markdown link with the
 * `comma:` scheme — `[Fix login](comma:task/cnv1_abc)` — so the agent reads a
 * self-describing reference (title + canonical conversation id) with no new
 * transport field, other surfaces degrade to the readable title, and this
 * client re-projects the exact pattern back into the existing inline Task
 * chip. Only user-authored messages are parsed: assistant Task references
 * arrive as server-projected `conversation_ref` blocks and never enter here.
 */
const TASK_MENTION_HREF_PREFIX = "comma:task/";
const TASK_MENTION_PATTERN =
  /\[([^\]\n]+)\]\(comma:task\/([A-Za-z0-9][A-Za-z0-9._-]*)\)/gu;

function mentionLabel(text: string, fallback: string) {
  return (
    text.replaceAll("[", "(").replaceAll("]", ")").replaceAll(/\s+/gu, " ").trim() ||
    fallback
  );
}

/** Builds the mention link; the label must already be non-empty. */
export function taskMentionPlainText(title: string, conversationId: string) {
  return `[${mentionLabel(title, conversationId)}](${TASK_MENTION_HREF_PREFIX}${conversationId})`;
}

/**
 * A routine link mention is an ordinary markdown link — real URLs stay
 * readable to the agent and render as links everywhere. Parens in the href
 * are percent-encoded so the markdown link cannot close early.
 */
export function linkMentionPlainText(label: string, href: string) {
  const safeHref = href.replaceAll("(", "%28").replaceAll(")", "%29");
  return `[${mentionLabel(label, safeHref)}](${safeHref})`;
}

export interface TaskMentionMatch {
  conversationId: string;
  /** Offset just past the mention. */
  end: number;
  start: number;
  /** The mention exactly as written. */
  text: string;
  title: string;
}

/** Every task mention in `text`, in order, with where it sits. */
export function* taskMentionMatches(text: string): Generator<TaskMentionMatch> {
  if (!text.includes(TASK_MENTION_HREF_PREFIX)) return;
  for (const match of text.matchAll(TASK_MENTION_PATTERN)) {
    const [full, title, conversationId] = match;
    if (!title || !conversationId) continue;
    yield {
      conversationId,
      end: match.index + full.length,
      start: match.index,
      text: full,
      title,
    };
  }
}

/**
 * Splits a user message's text into markdown and inline-task parts. Returns
 * undefined when the text carries no mention so callers keep the cheap
 * single-part path (and its identity stability) for ordinary messages.
 */
export function splitUserTaskMentionParts(text: string): ChatMessagePart[] | undefined {
  if (!text.includes(TASK_MENTION_HREF_PREFIX)) {
    return undefined;
  }

  const parts: ChatMessagePart[] = [];
  let offset = 0;
  for (const match of text.matchAll(TASK_MENTION_PATTERN)) {
    const [full, title, conversationId] = match;
    if (!title || !conversationId) continue;
    if (match.index > offset) {
      parts.push({ kind: "markdown", text: text.slice(offset, match.index) });
    }
    parts.push({
      kind: "inline-task",
      task: { conversationId, title, unavailable: false },
    });
    offset = match.index + full.length;
  }

  if (parts.length === 0) {
    return undefined;
  }
  if (offset < text.length) {
    parts.push({ kind: "markdown", text: text.slice(offset) });
  }
  return parts;
}
