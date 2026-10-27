// Coding sessions: Tasks that run on a cloud sandbox of their own with a GitHub repository checked out
// (`runs_on {kind: sandbox}`). Everything goes through the Comma API, which asks the sandbox's station through Salix,
// so web and desktop work the same and no station need be reached from here.
//
// - `coding.repos`, `coding.branches`: one page (100) of what the workspace's connected GitHub account reaches.
// - `coding.start`: a coding Task with its first message, owned by the person; made once per `key`.
// - `coding.session`: where the session stands: its repository and branch, and its sandbox's state.
// - `coding.changes`: the session branch's changes, from the sandbox, or from GitHub once the sandbox is gone.
// - `coding.history`: a page of the Session's execution history and its token use, from the sandbox
//   (coding-history.ts makes the entries into items).
// - `coding.pullRequest`, `coding.updatePullRequest`, `coding.mergePullRequest`: open, edit and merge the branch's pull
//   request; what the core knows of it is the `codingPullRequest` topic (coding-pull-requests.ts).
// - `coding.terminal`: the link to the sandbox's web terminal on L4ES, which the member opens signed in with Comma.
//
// Bounds: each call is one request, made when the person asks; reads of the same changes asked while one is on its way
// (the Task's surfaces after a turn) share its answer.
import { CoreError } from "@comma/core-kernel";
import { Deferred, Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { historyItems } from "./coding-history.ts";
import { pullRequestSchema, toPullRequest, usageSchema } from "./coding-wire.ts";
import { CodingPullRequests } from "./coding-pull-requests.ts";
import type {
  CodingChanges,
  CodingHistory,
  CodingRepo,
  CodingSession,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const text = (raw: unknown, name: string, max = 256): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v.trim() === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

/** A commit, named by its full sha. */
const SHA = /^[0-9a-f]{40}$/;

/** A description's longest: GitHub keeps 65 536 characters. */
const BODY_CHARS = 60_000;

const optional = (raw: unknown, name: string, max = 256): string | undefined => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  return typeof v === "string" && v !== "" && v.length <= max ? v : undefined;
};

const page = (raw: unknown): number => {
  const v = (raw as Record<string, unknown> | null)?.page;
  return typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= 100 ? v : 1;
};

const repoSchema = z.object({
  owner: z.string(),
  name: z.string(),
  default_branch: z.string().nullish(),
  private: z.boolean().optional(),
  pushed_at: z.string().nullish(),
});

const pullRequestAnswer = z.object({ pull_request: pullRequestSchema.nullable() });

const changesSchema = z.object({
  source: z.enum(["sandbox", "github"]),
  base: z.string().optional(),
  branch: z.string().optional(),
  truncated: z.boolean().optional(),
  files: z
    .array(
      z.object({
        path: z.string(),
        status: z.string(),
        additions: z.number().nullish(),
        deletions: z.number().nullish(),
        patch: z.string().nullish(),
      })
    )
    .max(1000),
  pull_request: pullRequestSchema.nullish(),
  commits: z
    .array(
      z.object({
        sha: z.string(),
        title: z.string(),
        author: z.string().nullish(),
        at: z.string().nullish(),
      })
    )
    .max(250)
    .optional(),
  uncommitted: z.boolean().optional(),
});

const historySchema = z.object({
  available: z.boolean(),
  start: z.number().int().min(0),
  total: z.number().int().min(0),
  entries: z
    .array(
      z.object({
        at: z.string().nullable(),
        kind: z.string(),
        text: z.string(),
        tool: z.string().optional(),
        ok: z.boolean().optional(),
        callId: z.string().optional(),
        subagent: z.boolean().optional(),
      })
    )
    .max(200),
  usage: usageSchema.nullish(),
});

const sessionSchema = z.object({
  repo: z.object({
    owner: z.string(),
    name: z.string(),
    base_ref: z.string().nullish(),
    branch: z.string().nullish(),
  }),
  state: z.enum(["starting", "ready", "stopped", "lost", "failed", "ended"]),
  reason: z.string().nullish(),
});

const base = (workspace: string) => route`/v1/comma/workspaces/${workspace}/coding`;

export function registerCoding(ctx: Ctx): void {
  const request = <S extends z.ZodType>(
    method: "GET" | "POST" | "PATCH",
    path: string,
    schema: S,
    body?: unknown
  ) =>
    ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );

  const pullRequests = new CodingPullRequests(ctx, (workspaceId, taskId) =>
    request(
      "GET",
      `${base(workspaceId)}${route`/sessions/${taskId}`}/pull-request`,
      pullRequestAnswer
    ).pipe(
      Effect.map(({ pull_request }) =>
        pull_request ? toPullRequest(pull_request) : null
      )
    )
  );
  // The changes reads on their way, by what they read: one asked again meanwhile waits for the same answer.
  const changesReads = new Map<string, Deferred.Deferred<CodingChanges, CoreError>>();

  ctx.kernel.calls({
    "coding.repos": {
      run: (p) =>
        request(
          "GET",
          `${base(text(p, "workspaceId"))}/repos?page=${page(p)}`,
          z.object({ repos: z.array(repoSchema).max(100) })
        ).pipe(
          Effect.map(({ repos }) =>
            repos.map(
              (r): CodingRepo => ({
                owner: r.owner,
                name: r.name,
                defaultBranch: r.default_branch ?? null,
                private: r.private ?? false,
              })
            )
          )
        ),
    },
    "coding.branches": {
      run: (p) =>
        request(
          "GET",
          `${base(text(p, "workspaceId"))}${route`/repos/${text(p, "owner", 100)}/${text(p, "name", 100)}/branches`}?page=${page(p)}`,
          z.object({ branches: z.array(z.string()).max(100) })
        ).pipe(Effect.map(({ branches }) => branches)),
    },
    "coding.start": {
      doing: true,
      run: (p) => {
        const repo = (p as { repo?: Record<string, unknown> } | null)?.repo;
        const provider = (p as { model?: { provider?: unknown } } | null)?.model
          ?.provider;
        const model = (p as { model?: Record<string, unknown> } | null)?.model;
        const body = {
          client_request_id: text(p, "key", 128),
          text: text(p, "text", 16_000),
          repo: {
            owner: text(repo, "owner", 100),
            name: text(repo, "name", 100),
            ...(optional(repo, "baseRef")
              ? { base_ref: optional(repo, "baseRef") }
              : {}),
          },
          ...(provider === "claude" || provider === "codex"
            ? {
                model: {
                  provider,
                  ...(optional(model, "model")
                    ? { model: optional(model, "model") }
                    : {}),
                  ...(optional(model, "effort", 32)
                    ? { effort: optional(model, "effort", 32) }
                    : {}),
                },
              }
            : {}),
          ...(optional(p, "accountId", 128)
            ? { account_id: optional(p, "accountId", 128) }
            : {}),
        };
        return request(
          "POST",
          `${base(text(p, "workspaceId"))}/sessions`,
          z.object({ task_id: z.string(), group_id: z.string() }),
          body
        ).pipe(
          Effect.map((made) => ({ taskId: made.task_id, groupId: made.group_id }))
        );
      },
    },
    "coding.session": {
      run: (p) =>
        request(
          "GET",
          `${base(text(p, "workspaceId"))}${route`/sessions/${text(p, "taskId")}`}`,
          sessionSchema
        ).pipe(
          Effect.map(
            (s): CodingSession => ({
              repo: {
                owner: s.repo.owner,
                name: s.repo.name,
                baseRef: s.repo.base_ref ?? null,
                branch: s.repo.branch ?? null,
              },
              state: s.state,
              reason: s.reason ?? null,
            })
          )
        ),
    },
    "coding.changes": {
      run: (p) => {
        const scope = p as { commit?: unknown; uncommitted?: unknown } | null;
        const query =
          typeof scope?.commit === "string" && SHA.test(scope.commit)
            ? `?commit=${scope.commit}`
            : scope?.uncommitted === true
              ? "?uncommitted=1"
              : "";
        const workspaceId = text(p, "workspaceId");
        const taskId = text(p, "taskId");
        const key = JSON.stringify([workspaceId, taskId, query]);
        // The whole branch's read carries its pull request, learned for every surface of the Task.
        const ticket = query === "" ? pullRequests.ticket() : null;
        const read = request(
          "GET",
          `${base(workspaceId)}${route`/sessions/${taskId}`}/changes${query}`,
          changesSchema
        ).pipe(
          Effect.map(
            (c): CodingChanges => ({
              source: c.source,
              base: c.base ?? null,
              branch: c.branch ?? null,
              truncated: c.truncated ?? false,
              files: c.files.map((f) => ({
                path: f.path,
                status: f.status,
                additions: f.additions ?? 0,
                deletions: f.deletions ?? 0,
                patch: f.patch ?? null,
              })),
              pullRequest: c.pull_request ? toPullRequest(c.pull_request) : null,
              commits: (c.commits ?? []).map((k) => ({
                sha: k.sha,
                title: k.title,
                author: k.author ?? "",
                at: k.at ?? null,
              })),
              uncommitted: c.uncommitted ?? false,
            })
          ),
          Effect.tap((changes) =>
            Effect.sync(() => {
              if (ticket !== null)
                pullRequests.learn(workspaceId, taskId, ticket, changes.pullRequest);
            })
          )
        );
        return Effect.gen(function* () {
          const shared = changesReads.get(key);
          if (shared) return yield* Deferred.await(shared);
          const answer = yield* Deferred.make<CodingChanges, CoreError>();
          changesReads.set(key, answer);
          // It runs to its end for whoever waits on it, even if the one that asked first lets go.
          ctx.runner.fork(
            read.pipe(
              Effect.exit,
              Effect.flatMap((exit) => Deferred.done(answer, exit)),
              Effect.ensuring(Effect.sync(() => changesReads.delete(key)))
            )
          );
          return yield* Deferred.await(answer);
        });
      },
    },
    "coding.history": {
      run: (p) => {
        const before = (p as { before?: unknown } | null)?.before;
        const query =
          typeof before === "number" && Number.isInteger(before) && before >= 0
            ? `?before=${before}`
            : "";
        return request(
          "GET",
          `${base(text(p, "workspaceId"))}${route`/sessions/${text(p, "taskId")}`}/history${query}`,
          historySchema
        ).pipe(
          Effect.map(
            (h): CodingHistory => ({
              available: h.available,
              start: h.start,
              total: h.total,
              items: historyItems(h.entries, h.start),
              usage: h.usage ?? null,
            })
          )
        );
      },
    },
    "coding.pullRequest": {
      doing: true,
      run: (p) => {
        const workspaceId = text(p, "workspaceId");
        const taskId = text(p, "taskId");
        const draft = (p as { draft?: unknown } | null)?.draft === true;
        const made = request(
          "POST",
          `${base(workspaceId)}${route`/sessions/${taskId}`}/pull-request`,
          z.object({
            url: z.string(),
            number: z.number().nullish(),
            title: z.string().nullish(),
          }),
          {
            draft,
            ...(optional(p, "title") ? { title: optional(p, "title") } : {}),
            ...(optional(p, "body", BODY_CHARS)
              ? { body: optional(p, "body", BODY_CHARS) }
              : {}),
          }
        ).pipe(
          Effect.map((pr) => ({
            url: pr.url,
            number: pr.number ?? null,
            title: pr.title ?? null,
          }))
        );
        return pullRequests
          .act(workspaceId, taskId, made, (pr) => ({
            // Made just now: open (or a draft); how it merges, its head and its checks come with the read that follows.
            url: pr.url,
            number: pr.number,
            title: pr.title,
            body: null,
            headSha: null,
            state: draft ? "draft" : "open",
            mergeable: "unknown",
            checks: null,
            newCommits: false,
          }))
          .pipe(
            Effect.tap(() =>
              Effect.sync(() =>
                ctx.runner.fork(
                  pullRequests.read(workspaceId, taskId).pipe(Effect.ignore)
                )
              )
            )
          );
      },
    },
    "coding.updatePullRequest": {
      doing: true,
      run: (p) => {
        const raw = p as { body?: unknown; ready?: unknown } | null;
        // A description may be cleared, so an empty one is sent as it is.
        const body =
          typeof raw?.body === "string" && raw.body.length <= BODY_CHARS
            ? raw.body
            : undefined;
        const workspaceId = text(p, "workspaceId");
        const taskId = text(p, "taskId");
        return pullRequests.act(
          workspaceId,
          taskId,
          request(
            "PATCH",
            `${base(workspaceId)}${route`/sessions/${taskId}`}/pull-request`,
            pullRequestAnswer,
            {
              ...(optional(p, "title") ? { title: optional(p, "title") } : {}),
              ...(body === undefined ? {} : { body }),
              ...(raw?.ready === true ? { ready: true } : {}),
            }
          ).pipe(
            Effect.map(({ pull_request }) =>
              pull_request ? toPullRequest(pull_request) : null
            )
          ),
          (pr) => pr
        );
      },
    },
    "coding.mergePullRequest": {
      doing: true,
      run: (p) => {
        const number = (p as { number?: unknown } | null)?.number;
        if (typeof number !== "number" || !Number.isSafeInteger(number) || number <= 0)
          throw CoreError.invalid("number must name the pull request");
        const headSha = text(p, "headSha", 40);
        if (!SHA.test(headSha))
          throw CoreError.invalid("headSha must be a full commit sha");
        const workspaceId = text(p, "workspaceId");
        const taskId = text(p, "taskId");
        return pullRequests.act(
          workspaceId,
          taskId,
          request(
            "POST",
            `${base(workspaceId)}${route`/sessions/${taskId}`}/pull-request/merge`,
            z.object({
              method: z.string(),
              pull_request: pullRequestSchema.nullable(),
            }),
            { number, head_sha: headSha }
          ).pipe(
            Effect.map(({ method, pull_request }) => ({
              method,
              pullRequest: pull_request ? toPullRequest(pull_request) : null,
            }))
          ),
          (merged) => merged.pullRequest
        );
      },
    },
    "coding.terminal": {
      doing: true,
      run: (p) =>
        request(
          "POST",
          `${base(text(p, "workspaceId"))}${route`/sessions/${text(p, "taskId")}`}/terminal`,
          z.object({ url: z.string().url() }),
          {}
        ).pipe(Effect.map(({ url }) => ({ url }))),
    },
  });
}
