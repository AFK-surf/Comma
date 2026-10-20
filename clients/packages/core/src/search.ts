// Search in the command palette: a workspace Group's Tasks matching what the person typed. A search is a call the page
// cancels when the query changes; the core waits 180 ms before it asks, so a query typed past asks nothing.
//
// Bounds: one request per query that stays typed for 180 ms; at most 20 results.
import { CoreError, Priority } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { taskSearchResultSchema } from "./comma/schemas.ts";
import type { TaskSearchValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

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
          const raw = p as {
            query?: unknown;
            group?: unknown;
            prefer?: unknown;
          } | null;
          if (typeof raw?.query !== "string")
            throw CoreError.invalid("query is required");
          const query = Array.from(raw.query.trim().normalize("NFKC"))
            .slice(0, MAX_CODEPOINTS)
            .join("");
          const group = typeof raw.group === "string" ? raw.group : "";
          const prefer = typeof raw.prefer === "string" ? raw.prefer : "";
          return this.#search(query, group, prefer);
        },
      },
    });
  }

  #search(
    query: string,
    group: string,
    prefer: string
  ): Effect.Effect<TaskSearchValue, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      if (Array.from(query).length < MIN_CODEPOINTS)
        return {
          status: "invalid",
          scope: null,
          results: [],
        } satisfies TaskSearchValue;
      yield* Effect.sleep(DEBOUNCE_MS);
      const account = yield* ctx.session.account();
      let scope: TaskSearchValue["scope"];
      if (group) scope = { groupId: group, workspaceId: prefer };
      else {
        if (!this.#workspaces.list(account)?.length)
          yield* this.#workspaces.refresh(Priority.asked).pipe(Effect.ignore);
        const list = this.#workspaces.list(account) ?? [];
        const workspace = list.find((w) => w.id === prefer) ?? list[0];
        if (!workspace)
          return {
            status: this.#workspaces.listFailure() ? "error" : "ready",
            scope: null,
            results: [],
          } satisfies TaskSearchValue;
        scope = { groupId: workspace.group_id, workspaceId: workspace.id };
      }
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
