import { describe, expect, it } from "vitest";
import type { CommaSkill } from "../../../../api";
import {
  deriveMentionedSkills,
  detectMentionTrigger,
  filterSkills,
  insertMention,
} from "../mentions";

const skills: CommaSkill[] = [
  skill("weekly-summary", "Weekly Summary", "Summarize meetings"),
  skill("code-review", "Code Review", "Review pull requests"),
  skill("code_review", "Code Review Underscore", "Underscore ids"),
  skill("task-cleanup", "Task Cleanup", "Clean old tasks"),
];

describe("skill mention helpers", () => {
  it("detects slash triggers only at token boundaries", () => {
    expect(detectMentionTrigger("/", 1)).toEqual({ start: 0, query: "" });
    expect(detectMentionTrigger("hello /cod", 10)).toEqual({
      start: 6,
      query: "cod",
    });
    expect(detectMentionTrigger("a/b", 3)).toBeNull();
    expect(detectMentionTrigger("https://", 8)).toBeNull();
    expect(detectMentionTrigger("hello /code review", 18)).toBeNull();
    expect(detectMentionTrigger("hello /code then", 11)).toEqual({
      start: 6,
      query: "code",
    });
  });

  it("filters, ranks, excludes, and caps menu skills", () => {
    expect(filterSkills("co", skills, new Set()).map((item) => item.skill_id)).toEqual([
      "code-review",
      "code_review",
    ]);
    expect(
      filterSkills("pull", skills, new Set()).map((item) => item.skill_id)
    ).toEqual(["code-review"]);
    expect(
      filterSkills("summary", skills, new Set([skills[0]!.location])).map(
        (item) => item.skill_id
      )
    ).toEqual([]);

    const many = Array.from({ length: 12 }, (_, index) =>
      skill(`skill-${index}`, `Skill ${index}`, "many")
    );
    expect(filterSkills("skill", many, new Set())).toHaveLength(8);
  });

  it("inserts mention tokens and derives selected locations from text", () => {
    const trigger = detectMentionTrigger("please /cod soon", 11);
    expect(trigger).toEqual({ start: 7, query: "cod" });
    if (!trigger) {
      throw new Error("expected mention trigger");
    }

    const inserted = insertMention("please /cod soon", trigger, 11, skills[1]!);
    expect(inserted).toEqual({
      text: "please /code-review  soon",
      caret: 20,
    });

    expect(
      deriveMentionedSkills(
        "/weekly-summary, then /CODE-REVIEW and /code_review /unknown /weekly-summary",
        skills
      )
    ).toEqual([
      { location: "/.runtime/skills/weekly-summary/SKILL.md" },
      { location: "/.runtime/skills/code-review/SKILL.md" },
      { location: "/.runtime/skills/code_review/SKILL.md" },
    ]);
  });
});

function skill(skillId: string, name: string, description: string): CommaSkill {
  return {
    skill_id: skillId,
    name,
    description,
    location: `/.runtime/skills/${skillId}/SKILL.md`,
  };
}
