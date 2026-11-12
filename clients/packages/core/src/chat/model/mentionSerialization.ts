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

const MODEL_MENTION_HREF_PREFIX = "comma:model/";
const MODEL_MENTION_PATTERN =
  /\[([^\]\n]{1,200})\]\(comma:model\/([A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}?)(?:\?effort=([a-z_]{1,32}))?\)/gu;

/**
 * A model mention in the Router chat, `[GPT 5.5](comma:model/gpt-5.5)`: the server starts a Task with that model and
 * the rest of the message, instead of the Router's turn (`SalixIM.ModelMentionTask`).
 */
export function modelMentionPlainText(name: string, modelId: string, effort?: string) {
  const query = effort ? `?effort=${effort}` : "";
  return `[${mentionLabel(name, modelId)}](${MODEL_MENTION_HREF_PREFIX}${modelId}${query})`;
}

export interface ModelMentionMatch {
  modelId: string;
  /** The thinking effort it names; the model's default without one. */
  effort?: string;
  /** Offset just past the mention. */
  end: number;
  start: number;
  /** The mention exactly as written. */
  text: string;
  name: string;
}

/** Every model mention in `text`, in order, with where it sits. */
export function* modelMentionMatches(text: string): Generator<ModelMentionMatch> {
  if (!text.includes(MODEL_MENTION_HREF_PREFIX)) return;
  for (const match of text.matchAll(MODEL_MENTION_PATTERN)) {
    const [full, name, modelId, effort] = match;
    if (!name || !modelId) continue;
    yield {
      modelId,
      ...(effort ? { effort } : {}),
      end: match.index + full.length,
      start: match.index,
      text: full,
      name,
    };
  }
}

/** A person's words as shown: each model mention as `@name`. */
export function modelMentionsAsWords(text: string): string {
  if (!text.includes(MODEL_MENTION_HREF_PREFIX)) return text;
  return text.replaceAll(MODEL_MENTION_PATTERN, (_full, name: string) => `@${name}`);
}

const REQUEST_MENTION_HREF_PREFIX = "comma:request/";
const REQUEST_MENTION_PATTERN =
  /\[([^\]\n]{1,200})\]\(comma:request\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\)/gu;

/**
 * A person mentioned in the Router chat to ask for a Task, `[CatsJuice](comma:request/trg_1)` (their grant): the server
 * sends the rest of the message to them as a Task request, instead of the Router's turn (`SalixIM.RequestMention`).
 */
export function requestMentionPlainText(name: string, grantId: string) {
  return `[${mentionLabel(name, grantId)}](${REQUEST_MENTION_HREF_PREFIX}${grantId})`;
}

export interface RequestMentionMatch {
  grantId: string;
  /** Offset just past the mention. */
  end: number;
  start: number;
  /** The mention exactly as written. */
  text: string;
  name: string;
}

/** Every request mention in `text`, in order, with where it sits. */
export function* requestMentionMatches(text: string): Generator<RequestMentionMatch> {
  if (!text.includes(REQUEST_MENTION_HREF_PREFIX)) return;
  for (const match of text.matchAll(REQUEST_MENTION_PATTERN)) {
    const [full, name, grantId] = match;
    if (!name || !grantId) continue;
    yield {
      grantId,
      end: match.index + full.length,
      start: match.index,
      text: full,
      name,
    };
  }
}

/** A person's words as shown: each request mention as `@name`. */
export function requestMentionsAsWords(text: string): string {
  if (!text.includes(REQUEST_MENTION_HREF_PREFIX)) return text;
  return text.replaceAll(REQUEST_MENTION_PATTERN, (_full, name: string) => `@${name}`);
}

const SLACK_MENTION_HOST = "https://app.slack.com/";
const SLACK_PERSON_LINK = String.raw`\(https://app\.slack\.com/team/([A-Za-z0-9]{1,64})\)`;
const SLACK_MENTION_PATTERN = new RegExp(
  String.raw`\[Slack #([^\]\n]{1,200})\]\(https://app\.slack\.com/client/([A-Za-z0-9]{1,64})/([A-Za-z0-9]{1,64})\)` +
    String.raw`(?: \[Slack @([^\]\n]{1,200})\]${SLACK_PERSON_LINK})?` +
    String.raw`|\[Slack (?:DM )?@([^\]\n]{1,200})\]${SLACK_PERSON_LINK}`,
  "gu"
);

export interface SlackMentionMatch {
  /** The channel it names, with or without a person in it. */
  channel?: { id: string; name: string; teamId: string };
  /** The person it names: in the channel, or alone for a direct message. */
  person?: { id: string; name: string };
  /** Offset just past the mention. */
  end: number;
  start: number;
  /** The mention exactly as written. */
  text: string;
}

/**
 * Every Slack mention in `text`, in order: the links the "@" menu writes for a channel, a person in a channel
 * (both links, one mention) and a direct message.
 */
export function* slackMentionMatches(text: string): Generator<SlackMentionMatch> {
  if (!text.includes(SLACK_MENTION_HOST)) return;
  for (const match of text.matchAll(SLACK_MENTION_PATTERN)) {
    const [full, channel, teamId, channelId, member, memberId, direct, directId] =
      match;
    const name = member ?? direct;
    const id = memberId ?? directId;
    yield {
      ...(channel && teamId && channelId
        ? { channel: { id: channelId, name: channel, teamId } }
        : {}),
      ...(name && id ? { person: { id, name } } : {}),
      end: match.index + full.length,
      start: match.index,
      text: full,
    };
  }
}

/** A Slack mention by name, as its chip and the composer's token show it. */
export function slackMentionLabel({ channel, person }: SlackMentionMatch) {
  if (!channel) return person?.name ?? "";
  return person ? `#${channel.name} · ${person.name}` : `#${channel.name}`;
}

/** A person's words as shown: each Slack mention as `#channel` and `@name`. */
export function slackMentionsAsWords(text: string): string {
  if (!text.includes(SLACK_MENTION_HOST)) return text;
  let words = "";
  let offset = 0;
  for (const mention of slackMentionMatches(text)) {
    const { channel, person } = mention;
    words += text.slice(offset, mention.start);
    words += [channel && `#${channel.name}`, person && `@${person.name}`]
      .filter(Boolean)
      .join(" ");
    offset = mention.end;
  }
  return words + text.slice(offset);
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
