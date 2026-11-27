// Search Tasks: one request for each query, and the view that the newest query leaves.
import { Unauthorized, searchQuery, type ApiTaskHit, type CommaApi } from "./api";
import { inWorkspace } from "./ask";
import type { CommaStore, Workspace } from "./store";

/** What the person searches for, and what the server found. No view shows the list of Tasks. */
export interface SearchView {
  query: string;
  /** A request for `query` is under way. */
  loading: boolean;
  workspace?: Workspace | undefined;
  /** The Tasks found. While a new query loads, the hits of the last good one stay. */
  hits?: ApiTaskHit[] | undefined;
  /** The search failed. It is not the same as no Tasks found. */
  failed?: boolean | undefined;
}

type SearchChange = (before: SearchView | undefined) => SearchView | undefined;
export type SearchUpdate = SearchView | undefined | SearchChange;

export interface TaskSearchDeps {
  store: CommaStore;
  /** The API with `token`'s session. */
  api(token: string): CommaApi;
  onChange(update: SearchUpdate): void;
  onSignedOut(): void;
  onChooseWorkspace(): void;
  /** Tells the person that the search failed. The view already shows it. */
  onError(): Promise<unknown>;
}

export interface TaskSearch {
  /** Searches for `typed`. `force` asks again for the query already shown, to retry it. */
  run(typed: string, options?: { force?: boolean }): Promise<void>;
}

export function createTaskSearch(deps: TaskSearchDeps): TaskSearch {
  /** The newest search. An answer to an older one is dropped. */
  let asked = 0;
  /** The query last asked for. The same query again sends no request, unless it failed. */
  let lastQuery = "";

  return {
    async run(typed, options) {
      const query = searchQuery(typed);
      if (!query) {
        lastQuery = "";
        ++asked;
        return deps.onChange(undefined);
      }
      if (!options?.force && query === lastQuery) return;
      lastQuery = query;
      const turn = ++asked;
      // Keep the last good hits while the new ones load; drop a failure at once.
      deps.onChange((before) => ({
        query,
        loading: true,
        workspace: before?.workspace,
        hits: before?.failed ? undefined : before?.hits,
      }));
      try {
        const session = await deps.store.session();
        if (turn !== asked) return;
        if (!session) return deps.onSignedOut();
        const client = deps.api(session.token);
        const read = await inWorkspace(deps.store, client, (workspace) =>
          client.search(workspace.groupId, query)
        );
        if (turn !== asked) return;
        if (!read) return deps.onChooseWorkspace();
        deps.onChange({
          query,
          loading: false,
          workspace: read.workspace,
          hits: read.value,
        });
      } catch (error) {
        if (turn !== asked) return;
        if (error instanceof Unauthorized) {
          await deps.store.clearSession();
          return deps.onSignedOut();
        }
        // Show the failure before the toast: a query typed while the toast shows must not be overwritten.
        lastQuery = "";
        deps.onChange({ query, loading: false, failed: true });
        await deps.onError();
      }
    },
  };
}
