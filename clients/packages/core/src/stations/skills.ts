// The skills a person tags on a message of a Task a station hosts, as Salix gives them to its agent
// (`Comma.SkillMentions`): after the protocol marker, which no page shows, a line that says to follow each. Salix's
// agent reads a skill's SKILL.md where the workspace keeps it; a station's cannot, so its SKILL.md and its text files
// come in the block itself, read from Comma's server as the person sends.
//
// Bounds: at most MAX_SKILLS skills a message; one read of the workspace's skills, then one of each skill and one per
// file of it, until the block holds MAX_CHARS characters. A file past that is named, not read.
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import {
  commaSkillDetailSchema,
  commaSkillFileSchema,
  commaSkillSchema,
} from "../comma/api-schemas.ts";
import type { Ctx } from "../ctx.ts";

const MAX_SKILLS = 10;
const MAX_CHARS = 60_000;

/**
 * The block that gives the agent the skills `tagged` names (by their location); empty when none is the workspace's or
 * the workspace's skills cannot be read, as Salix sends the message then.
 */
export function skillsBlock(
  ctx: Ctx,
  account: Account,
  workspace: string,
  tagged: readonly { location: string }[]
): Effect.Effect<string> {
  return Effect.gen(function* () {
    if (tagged.length === 0) return "";
    const listed = yield* ctx.api.request(
      account,
      "GET",
      route`/v1/comma/workspaces/${workspace}/skills`,
      z.object({ data: z.array(commaSkillSchema) })
    );
    const skills = [...new Set(tagged.map((t) => t.location))]
      .slice(0, MAX_SKILLS)
      .flatMap((location) =>
        listed.data.filter((s) => s.location === location).slice(0, 1)
      );
    if (skills.length === 0) return "";
    let left = MAX_CHARS;
    const bodies: string[] = [];
    for (const skill of skills) {
      const detail = yield* ctx.api.request(
        account,
        "GET",
        route`/v1/comma/workspaces/${workspace}/skills/${skill.skill_id}`,
        commaSkillDetailSchema
      );
      const parts = [`SKILL.md:\n${detail.content.slice(0, Math.max(0, left))}`];
      left -= detail.content.length;
      for (const path of detail.files.filter((f) => f !== "SKILL.md")) {
        if (left <= 0) {
          parts.push(`${path}: not included (the skill is too long to send whole)`);
          continue;
        }
        const file = yield* ctx.api
          .request(
            account,
            "GET",
            `${route`/v1/comma/workspaces/${workspace}/skills/${skill.skill_id}/file`}?path=${encodeURIComponent(path)}`,
            commaSkillFileSchema
          )
          .pipe(Effect.match({ onFailure: () => null, onSuccess: (read) => read }));
        if (!file) {
          parts.push(`${path}: not included (not a text file)`);
          continue;
        }
        parts.push(`${path}:\n${file.content.slice(0, left)}`);
        left -= file.content.length;
      }
      bodies.push(
        `<skill name="${skill.name}" location="${skill.location}">\n${parts.join("\n\n")}\n</skill>`
      );
    }
    return [
      "The user tagged these skills for this message. Activate each one now: read its SKILL.md, given below with its " +
        "files (the workspace that keeps it is not on this machine), and follow it while doing the work:",
      ...skills.map((s) => `- ${s.name} — ${s.location}`),
      "",
      ...bodies,
    ].join("\n");
  }).pipe(Effect.orElseSucceed(() => ""));
}
