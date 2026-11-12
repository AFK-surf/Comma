import {
  createAiInputRichValue,
  type AiInputRichSegment,
  type AiInputRichValue,
} from "@comma/ui/components/ai-input";
import {
  modelMentionMatches,
  requestMentionMatches,
  slackMentionLabel,
  slackMentionMatches,
  taskMentionMatches,
} from "@comma/core/chat";
import { resolveProviderBrandLogo } from "@comma/ui/components/provider-brand-logos";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { skillMentionMatches } from "./mentions";

/** The composer's "@" menu, which the projected tokens belong to. */
export const MENTION_MENU_ID = "mentions";
/** The composer's "/" menu, which projected skill tokens belong to. */
export const SKILL_MENU_ID = "skills";

/** A skill the "/" menu offers, as its pill shows it. */
export type ProjectedSkill = {
  skillId: string;
  label: string;
  description: string;
  location: string;
  /** The pill's glyph, as the menu option draws it. */
  iconMarkup: string;
};

type Projected = {
  start: number;
  end: number;
  token: (index: number) => AiInputRichSegment;
};

/**
 * Brings a draft that arrived as text (restored, or handed over by another
 * surface such as the Tasks page or a skill's "Try in Chat") back into composer
 * pills: each task, model, request or Slack mention becomes the same token the "@"
 * menu would have inserted, and each `/<skill>` of `skills` the token the "/"
 * menu would have; the words between stay text. Typing never comes through here.
 */
export function projectMentionTokens(
  text: string,
  skills: readonly ProjectedSkill[] = []
): AiInputRichValue {
  const found: Projected[] = [];
  const skillById = new Map(
    skills.map((skill) => [skill.skillId.toLowerCase(), skill])
  );
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
  for (const mention of requestMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      token: (index) => ({
        type: "token",
        instanceId: `projected-${index}-${mention.grantId}`,
        menuId: MENTION_MENU_ID,
        itemId: `request:${mention.grantId}`,
        trigger: "@",
        label: mention.name,
        plainText: mention.text,
        data: { kind: "request", grantId: mention.grantId },
      }),
    });
  for (const mention of slackMentionMatches(text)) {
    const { channel, person } = mention;
    const logo = resolveProviderBrandLogo("slack");
    const place = channel
      ? person
        ? `member:${channel.id}/${person.id}`
        : `channel:${channel.teamId}/${channel.id}`
      : `person:${person?.id}`;
    found.push({
      start: mention.start,
      end: mention.end,
      token: (index) => ({
        type: "token",
        instanceId: `projected-${index}-${place}`,
        menuId: MENTION_MENU_ID,
        itemId: place,
        trigger: "@",
        label: slackMentionLabel(mention),
        plainText: mention.text,
        ...(logo ? { iconMarkup: renderToStaticMarkup(createElement(logo)) } : {}),
        data: {
          kind: "routine-link",
          href: person
            ? `https://app.slack.com/team/${person.id}`
            : `https://app.slack.com/client/${channel?.teamId}/${channel?.id}`,
        },
      }),
    });
  }
  // A /skill inside a task, model, request or Slack mention is part of its title.
  for (const mention of skillMentionMatches(text)) {
    const skill = skillById.get(mention.skillId.toLowerCase());
    if (!skill) continue;
    if (found.some((other) => mention.start < other.end && other.start < mention.end))
      continue;
    found.push({
      start: mention.start,
      end: mention.end,
      token: (index) => ({
        type: "token",
        instanceId: `projected-${index}-${skill.skillId}`,
        menuId: SKILL_MENU_ID,
        itemId: skill.skillId,
        trigger: "/",
        label: skill.label,
        description: skill.description,
        iconMarkup: skill.iconMarkup,
        plainText: `/${skill.skillId}`,
        data: { location: skill.location },
      }),
    });
  }
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
