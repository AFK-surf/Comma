import {
  createAiInputRichValue,
  type AiInputRichSegment,
  type AiInputRichValue,
} from "@comma/ui";
import { taskMentionMatches } from "../model/mentionSerialization";

/** The composer's "@" menu, which the projected tokens belong to. */
export const MENTION_MENU_ID = "mentions";

/**
 * Brings a draft that arrived as text (restored, or handed over by another
 * surface such as the Tasks page) back into composer pills: each task mention
 * becomes the same token the "@" menu would have inserted, the words between
 * stay text. Typing never comes through here.
 */
export function projectMentionTokens(text: string): AiInputRichValue {
  const segments: AiInputRichSegment[] = [];
  let offset = 0;
  let index = 0;
  for (const mention of taskMentionMatches(text)) {
    if (mention.start > offset) {
      segments.push({ type: "text", text: text.slice(offset, mention.start) });
    }
    segments.push({
      type: "token",
      instanceId: `projected-${index}-${mention.conversationId}`,
      menuId: MENTION_MENU_ID,
      itemId: `task:${mention.conversationId}`,
      trigger: "@",
      label: mention.title,
      plainText: mention.text,
      data: { kind: "task", conversationId: mention.conversationId },
    });
    offset = mention.end;
    index += 1;
  }
  if (offset < text.length) segments.push({ type: "text", text: text.slice(offset) });
  return createAiInputRichValue(segments);
}
