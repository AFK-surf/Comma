// Search in the command palette: a workspace Group's Tasks matching what the person typed (`search.tasks`), and the
// files Agents attached to them whose name contains it (`search.taskFiles`). A search is a call the page cancels when
// the query changes; the core waits 180 ms before it asks, so a query typed past asks nothing. A Task opened from a
// hit asks once for all its Messages that match (`search.taskMessages`), to step through them.
//
// Bounds: one request per search and query that stays typed for 180 ms; at most 20 results each. One request per
// opened hit; the server answers at most a Task's indexed Messages (its latest 64).
import { CoreError, Priority } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { taskSearchResultSchema } from "./comma/schemas.ts";
import type {
  TaskFileSearchValue,
  TaskMessageSearchValue,
  TaskSearchValue,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { indexing, listTaskFiles } from "./task-files.ts";
import type { Workspaces } from "./workspaces.ts";
import type { Account } from "./account.ts";

const DEBOUNCE_MS = 180;
const LIMIT = 20;
const MIN_CODEPOINTS = 2;
const MAX_CODEPOINTS = 128;

export class Search {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    ctx.kernel.calls({
      "search.tasks": {
        cancellable: true,
        run: (p) => {
          const { query, group, prefer } = searchParams(p);
          return this.#search(query, group, prefer);
        },
      },
      "search.taskFiles": {
        cancellable: true,
        run: (p) => {
          const { query, group, prefer } = searchParams(p);
          return this.#searchFiles(query, group, prefer);
        },
      },
      "search.taskMessages": {
        cancellable: true,
        run: (p) => {
          const { query, group } = searchParams(p);
          const conversation = (p as { conversation?: unknown }).conversation;
          if (!group || typeof conversation !== "string" || !conversation)
            throw CoreError.invalid("group and conversation are required");
          return this.#searchMessages(query, group, conversation);
        },
      },
    });
  }

  /** The Group searched, after the wait; `none` when the query is too short, null when there is no workspace. */
  #scope(
    query: string,
    group: string,
    prefer: string
  ): Effect.Effect<
    { account: Account; scope: TaskSearchValue["scope"] } | "none",
    CoreError
  > {
    return Effect.gen({ self: this }, function* () {
      if (Array.from(query).length < MIN_CODEPOINTS) return "none" as const;
      yield* Effect.sleep(DEBOUNCE_MS);
      const account = yield* this.#ctx.session.account();
      if (group) return { account, scope: { groupId: group, workspaceId: prefer } };
      if (!this.#workspaces.list(account)?.length)
        yield* this.#workspaces.refresh(Priority.asked).pipe(Effect.ignore);
      const list = this.#workspaces.list(account) ?? [];
      const workspace = list.find((w) => w.id === prefer) ?? list[0];
      return {
        account,
        scope: workspace
          ? { groupId: workspace.group_id, workspaceId: workspace.id }
          : null,
      };
    });
  }

  #searchFiles(
    query: string,
    group: string,
    prefer: string
  ): Effect.Effect<TaskFileSearchValue, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const found = yield* this.#scope(query, group, prefer);
      if (found === "none")
        return {
          status: "invalid",
          scope: null,
          files: [],
        } satisfies TaskFileSearchValue;
      const { account, scope } = found;
      if (!scope)
        return {
          status: this.#workspaces.listFailure() ? "error" : "ready",
          scope: null,
          files: [],
        } satisfies TaskFileSearchValue;
      return yield* listTaskFiles(this.#ctx, account, scope.groupId, {
        query,
        limit: LIMIT,
      }).pipe(
        Effect.map(
          (page): TaskFileSearchValue => ({ status: "ready", scope, files: page.files })
        ),
        Effect.catch((error: CoreError) =>
          Effect.succeed<TaskFileSearchValue>({
            status: indexing(error)
              ? "indexing"
              : error.status === 400
                ? "invalid"
                : "error",
            scope,
            files: [],
          })
        )
      );
    });
  }

  #searchMessages(
    query: string,
    group: string,
    conversation: string
  ): Effect.Effect<TaskMessageSearchValue, CoreError> {
    const ctx = this.#ctx;
    if (Array.from(query).length < MIN_CODEPOINTS)
      return Effect.succeed({ status: "invalid", messageIds: [] });
    return Effect.gen(function* () {
      const account = yield* ctx.session.account();
      const params = new URLSearchParams({ q: query });
      return yield* ctx.api
        .request(
          account,
          "GET",
          `${route`/v1/comma/groups/${group}/conversations/${conversation}/search`}?${params}`,
          z.object({
            data: z.array(z.object({ message_id: z.string().min(1) }).strip()),
          })
        )
        .pipe(
          Effect.map(
            (page): TaskMessageSearchValue => ({
              status: "ready",
              messageIds: page.data.map((match) => match.message_id),
            })
          ),
          Effect.catch((error: CoreError) =>
            Effect.succeed<TaskMessageSearchValue>({
              status: error.status === 400 ? "invalid" : "error",
              messageIds: [],
            })
          )
        );
    });
  }

  #search(
    query: string,
    group: string,
    prefer: string
  ): Effect.Effect<TaskSearchValue, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const resolved = yield* this.#scope(query, group, prefer);
      if (resolved === "none")
        return {
          status: "invalid",
          scope: null,
          results: [],
        } satisfies TaskSearchValue;
      const { account, scope } = resolved;
      if (!scope)
        return {
          status: this.#workspaces.listFailure() ? "error" : "ready",
          scope: null,
          results: [],
        } satisfies TaskSearchValue;
      const params = new URLSearchParams({ limit: String(LIMIT), q: query });
      const found = scope;
      return yield* ctx.api
        .request(
          account,
          "GET",
          `${route`/v1/comma/groups/${scope.groupId}/conversations/search`}?${params}`,
          z.object({ data: z.array(taskSearchResultSchema) })
        )
        .pipe(
          Effect.map(
            (page): TaskSearchValue => ({
              status: "ready",
              scope: found,
              results: page.data,
            })
          ),
          Effect.catch((error: CoreError) =>
            Effect.succeed<TaskSearchValue>({
              status: error.status === 400 ? "invalid" : "error",
              scope: found,
              results: [],
            })
          )
        );
    });
  }
}

function searchParams(p: unknown): { query: string; group: string; prefer: string } {
  const raw = p as { query?: unknown; group?: unknown; prefer?: unknown } | null;
  if (typeof raw?.query !== "string") throw CoreError.invalid("query is required");
  return {
    query: Array.from(raw.query.trim().normalize("NFKC"))
      .slice(0, MAX_CODEPOINTS)
      .join(""),
    group: typeof raw.group === "string" ? raw.group : "",
    prefer: typeof raw.prefer === "string" ? raw.prefer : "",
  };
}
