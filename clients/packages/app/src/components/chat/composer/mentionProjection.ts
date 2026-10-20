import {
  createAiInputRichValue,
  type AiInputRichSegment,
  type AiInputRichValue,
} from "@comma/ui/components/ai-input";
import { modelMentionMatches, taskMentionMatches } from "@comma/core/chat";

/** The composer's "@" menu, which the projected tokens belong to. */
export const MENTION_MENU_ID = "mentions";

type Projected = {
  start: number;
  end: number;
  token: (index: number) => AiInputRichSegment;
};

/**
 * Brings a draft that arrived as text (restored, or handed over by another
 * surface such as the Tasks page) back into composer pills: each task or model
 * mention becomes the same token the "@" menu would have inserted, the words
 * between stay text. Typing never comes through here.
 */
export function projectMentionTokens(text: string): AiInputRichValue {
  const found: Projected[] = [];
  for (const mention of taskMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      token: (index) => ({
        type: "token",
        instanceId: `projected-${index}-${mention.conversationId}`,
        menuId: MENTION_MENU_ID,
        itemId: `task:${mention.conversationId}`,
        trigger: "@",
        label: mention.title,
        plainText: mention.text,
        data: { kind: "task", conversationId: mention.conversationId },
      }),
    });
  for (const mention of modelMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      token: (index) => ({
        type: "token",
        instanceId: `projected-${index}-${mention.modelId}`,
        menuId: MENTION_MENU_ID,
        itemId: `model:${mention.modelId}${mention.effort ? `:${mention.effort}` : ""}`,
        trigger: "@",
        label: mention.name,
        plainText: mention.text,
        data: {
          kind: "model",
          modelId: mention.modelId,
          effort: mention.effort ?? null,
        },
      }),
    });
  found.sort((a, b) => a.start - b.start);

  const segments: AiInputRichSegment[] = [];
  let offset = 0;
  for (const [index, mention] of found.entries()) {
    if (mention.start > offset) {
      segments.push({ type: "text", text: text.slice(offset, mention.start) });
    }
    segments.push(mention.token(index));
    offset = mention.end;
  }
  if (offset < text.length) segments.push({ type: "text", text: text.slice(offset) });
  return createAiInputRichValue(segments);
}
