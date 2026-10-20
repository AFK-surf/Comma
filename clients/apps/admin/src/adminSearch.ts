// The search behind ⌘K: an operator types an email or any id an account is known by (user, Workspace, Salix tenant,
// Agent group), and the server names the accounts (GET /v1/comma/admin/lookup). Each query waits a moment for the
// operator to stop typing; a newer query stops the one before.
import { messages } from "@comma/i18n";
import { Duration, Effect, FiberHandle, SubscriptionRef } from "effect";
import { AdminApi, type AdminLookupResult } from "./adminApi";

export const searchDelay = Duration.millis(200);
const minimumQueryLength = 2;

export type SearchResults =
  | { readonly status: "idle" }
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | { readonly status: "ready"; readonly results: ReadonlyArray<AdminLookupResult> };

export interface SearchState {
  readonly open: boolean;
  readonly query: string;
  readonly results: SearchResults;
}

export interface SearchModel {
  readonly state: SubscriptionRef.SubscriptionRef<SearchState>;
  readonly setOpen: (open: boolean) => Effect.Effect<void>;
  readonly setQuery: (query: string) => Effect.Effect<void>;
}

export const makeSearchModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const state = yield* SubscriptionRef.make<SearchState>({
    open: false,
    query: "",
    results: { status: "idle" },
  });
  const searching = yield* FiberHandle.make();

  const update = (change: (current: SearchState) => SearchState) =>
    SubscriptionRef.update(state, change);

  const search = (query: string) =>
    Effect.gen(function* () {
      yield* Effect.sleep(searchDelay);
      yield* update((current) => ({ ...current, results: { status: "loading" } }));
      yield* api.lookup(query).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            update((current) => ({
              ...current,
              results: {
                status: "error",
                message:
                  error instanceof Error && error.message
                    ? error.message
                    : messages.admin_search_failed(),
              },
            })),
          onSuccess: (lookup) =>
            update((current) =>
              current.query.trim() === query
                ? { ...current, results: { status: "ready", results: lookup.data } }
                : current
            ),
        })
      );
    });

  const model: SearchModel = {
    state,
    setOpen: (open) =>
      Effect.gen(function* () {
        if (!open) yield* FiberHandle.clear(searching);
        yield* update((current) =>
          open ? { ...current, open } : { open, query: "", results: { status: "idle" } }
        );
      }),
    setQuery: (query) =>
      Effect.gen(function* () {
        yield* update((current) => ({ ...current, query }));
        const trimmed = query.trim();
        if (trimmed.length < minimumQueryLength) {
          yield* FiberHandle.clear(searching);
          yield* update((current) => ({ ...current, results: { status: "idle" } }));
          return;
        }
        yield* FiberHandle.run(searching, search(trimmed));
      }),
  };
  return model;
});
