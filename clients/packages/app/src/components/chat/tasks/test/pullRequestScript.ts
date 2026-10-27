// The `codingPullRequest` topic for a scripted core, as the core keeps it (coding-pull-requests.ts, whose own tests
// cover how it learns, orders and polls): it says what the script's answers said of the Task's pull request. The whole
// branch's changes and the answers of the requests that open, edit or merge it are learned, `busy` while one of those
// is on its way; after one is made, the script's answer to `status` (if any) is learned, as the core reads its status
// from GitHub then.

type Calls = (name: string, params: unknown) => unknown;
type PullRequest = Record<string, unknown> | null;

const ACTS = new Set([
  "coding.pullRequest",
  "coding.updatePullRequest",
  "coding.mergePullRequest",
]);

export function pullRequestScript(calls: Calls) {
  let state: { known: boolean; pr: PullRequest; busy: boolean } = {
    known: false,
    pr: null,
    busy: false,
  };
  let core: { emit(topic: string, value: unknown): void } | null = null;
  const set = (next: Partial<typeof state>) => {
    state = { ...state, ...next };
    core?.emit("codingPullRequest", state);
  };
  return {
    values: (topic: Record<string, unknown>) =>
      topic.topic === "codingPullRequest" ? state : undefined,
    calls: async (name: string, params: unknown) => {
      const act = ACTS.has(name);
      if (act) set({ busy: true });
      try {
        const answer = (await calls(name, params)) as Record<string, unknown> | null;
        const asked = (params ?? {}) as {
          commit?: string;
          uncommitted?: boolean;
          draft?: boolean;
        };
        if (name === "coding.changes" && answer && !asked.commit && !asked.uncommitted)
          set({ known: true, pr: (answer.pullRequest as PullRequest) ?? null });
        else if (name === "coding.pullRequest" && answer) {
          set({
            known: true,
            pr: {
              url: answer.url,
              number: answer.number,
              title: answer.title,
              body: null,
              headSha: null,
              state: asked.draft ? "draft" : "open",
              mergeable: "unknown",
              checks: null,
              newCommits: false,
            },
          });
          const read = (await calls("status", params)) as PullRequest;
          if (read) set({ pr: read });
        } else if (name === "coding.updatePullRequest")
          set({ known: true, pr: answer });
        else if (name === "coding.mergePullRequest" && answer)
          set({ known: true, pr: (answer.pullRequest as PullRequest) ?? null });
        return answer;
      } finally {
        if (act) set({ busy: false });
      }
    },
    /** Hands it the core it is the topic of. */
    attach<C extends { emit(topic: string, value: unknown): void }>(scripted: C): C {
      core = scripted;
      return scripted;
    },
    /** What the core learned meanwhile (a read on another surface, the watch). */
    learn: (pr: PullRequest) => set({ known: true, pr }),
  };
}
