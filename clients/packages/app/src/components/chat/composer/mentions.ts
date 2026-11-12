import type { CommaSkill } from "@comma/core/api-schemas";

export type MentionTrigger = {
  query: string;
  start: number;
};

const mentionTriggerPattern = /(^|\s)\/([^\s/]*)$/u;
const mentionedSkillPattern = /(^|\s)\/([a-z0-9][a-z0-9_-]*)/giu;
const maxMenuItems = 8;
const maxMentions = 10;

export function detectMentionTrigger(
  text: string,
  caret: number
): MentionTrigger | null {
  const beforeCaret = text.slice(0, Math.max(0, caret));
  const match = mentionTriggerPattern.exec(beforeCaret);
  if (!match) {
    return null;
  }

  return {
    query: match[2] ?? "",
    start: match.index + (match[1]?.length ?? 0),
  };
}

export function filterSkills(
  query: string,
  skills: CommaSkill[],
  excludedLocations: Set<string>
) {
  const normalizedQuery = query.trim().toLowerCase();

  return skills
    .map((skill, index) => ({ index, rank: skillRank(skill, normalizedQuery), skill }))
    .filter(
      (entry): entry is { index: number; rank: number; skill: CommaSkill } =>
        entry.rank !== undefined && !excludedLocations.has(entry.skill.location)
    )
    .toSorted((a, b) => (a.rank === b.rank ? a.index - b.index : a.rank - b.rank))
    .slice(0, maxMenuItems)
    .map((entry) => entry.skill);
}

export function insertMention(
  text: string,
  trigger: MentionTrigger,
  caret: number,
  skill: CommaSkill
) {
  const inserted = `/${skill.skill_id} `;
  const nextText = text.slice(0, trigger.start) + inserted + text.slice(caret);

  return {
    caret: trigger.start + inserted.length,
    text: nextText,
  };
}

/**
 * Each `/<skill_id>` in the text, where it sits: the words a sent message
 * attaches skills by, and its bubble shows as them.
 */
export function* skillMentionMatches(text: string) {
  for (const match of text.matchAll(mentionedSkillPattern)) {
    const start = match.index + (match[1]?.length ?? 0);
    yield { end: match.index + match[0].length, skillId: match[2]!, start };
  }
}

export function deriveMentionedSkills(text: string, skills: CommaSkill[]) {
  const byId = new Map(skills.map((skill) => [skill.skill_id.toLowerCase(), skill]));
  const seen = new Set<string>();
  const selected: { location: string }[] = [];

  for (const { skillId } of skillMentionMatches(text)) {
    const skill = byId.get(skillId.toLowerCase());
    if (!skill || seen.has(skill.location)) {
      continue;
    }

    seen.add(skill.location);
    selected.push({ location: skill.location });
    if (selected.length >= maxMentions) {
      break;
    }
  }

  return selected;
}

function skillRank(skill: CommaSkill, query: string) {
  if (!query) {
    return 0;
  }

  const skillId = skill.skill_id.toLowerCase();
  const name = skill.name.toLowerCase();
  const description = (skill.description ?? "").toLowerCase();

  if (skillId.startsWith(query) || name.startsWith(query)) {
    return 0;
  }

  if (skillId.includes(query) || name.includes(query)) {
    return 1;
  }

  if (description.includes(query)) {
    return 2;
  }

  return undefined;
}
