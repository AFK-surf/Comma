import type { ChatSkill, ChatWorkspaceSkillsInput } from "@comma/chat-contract";
import { Effect } from "effect";
import type { ChatEnv } from "../../env";
import type { ChatSessionBoundary } from "../entries/sessionBoundary";

/** Each workspace's skills, cached per session boundary for five minutes. */
export class SkillsCache {
  readonly #openBoundary: () => ChatSessionBoundary;
  readonly #skills = new Map<string, { fetchedAt: number; skills: ChatSkill[] }>();

  readonly #env: ChatEnv;

  constructor(openBoundary: () => ChatSessionBoundary, env: ChatEnv) {
    this.#openBoundary = openBoundary;
    this.#env = env;
  }

  list(input: ChatWorkspaceSkillsInput): Effect.Effect<ChatSkill[], Error> {
    return Effect.suspend(() => {
      const boundary = this.#openBoundary();
      boundary.assertCurrent();
      const cacheKey = `${boundary.key}\u0000${input.workspaceId}`;
      const cached = this.#skills.get(cacheKey);
      if (cached && this.#env.now() - cached.fetchedAt < 5 * 60 * 1_000) {
        boundary.assertCurrent();
        return Effect.succeed(cached.skills);
      }
      return boundary.api.listWorkspaceSkills(input.workspaceId).pipe(
        Effect.map((skills) => {
          boundary.assertCurrent();
          this.#skills.set(cacheKey, { fetchedAt: this.#env.now(), skills });
          boundary.assertCurrent();
          return skills;
        })
      );
    });
  }

  clear() {
    this.#skills.clear();
  }
}
