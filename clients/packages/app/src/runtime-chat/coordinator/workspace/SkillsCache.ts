import type { ChatSkill, ChatWorkspaceSkillsInput } from "@comma/chat-contract";
import type { ChatSessionBoundary } from "../entries/sessionBoundary";

/** Each workspace's skills, cached per session boundary for five minutes. */
export class SkillsCache {
  readonly #openBoundary: () => ChatSessionBoundary;
  readonly #skills = new Map<string, { fetchedAt: number; skills: ChatSkill[] }>();

  constructor(openBoundary: () => ChatSessionBoundary) {
    this.#openBoundary = openBoundary;
  }

  async list(input: ChatWorkspaceSkillsInput): Promise<ChatSkill[]> {
    const boundary = this.#openBoundary();
    boundary.assertCurrent();
    const cacheKey = `${boundary.key}\u0000${input.workspaceId}`;
    const cached = this.#skills.get(cacheKey);
    if (cached && Date.now() - cached.fetchedAt < 5 * 60 * 1_000) {
      boundary.assertCurrent();
      return cached.skills;
    }
    const skills = await boundary.api.listWorkspaceSkills(input.workspaceId);
    boundary.assertCurrent();
    this.#skills.set(cacheKey, { fetchedAt: Date.now(), skills });
    boundary.assertCurrent();
    return skills;
  }

  clear() {
    this.#skills.clear();
  }
}
