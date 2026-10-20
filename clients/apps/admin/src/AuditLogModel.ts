// Audit log: privileged Admin commands, newest first, loaded in bounded pages.
import { Effect, FiberHandle, SubscriptionRef } from "effect";
import {
  AdminApi,
  AdminApiError,
  type AdminAuditEvent,
  type AdminAuditFilters,
} from "./adminApi";
import { makeFailures } from "./adminModel";
import { messages } from "@comma/i18n";

export const auditPageSize = 50;

export type AuditLogList =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | {
      readonly status: "ready";
      readonly events: ReadonlyArray<AdminAuditEvent>;
      readonly hasMore: boolean;
      readonly loadMoreError?: string | undefined;
      readonly loadingMore: boolean;
      readonly nextCursor?: string;
    };

export interface AuditLogState {
  /** The operator email being typed; it filters once submitted. */
  readonly actorDraft: string;
  /** The filters the list was read with. */
  readonly filters: AdminAuditFilters;
  readonly list: AuditLogList;
  /** The event whose detail drawer is open. */
  readonly selected: AdminAuditEvent | undefined;
}

export interface AuditLogModel {
  readonly state: SubscriptionRef.SubscriptionRef<AuditLogState>;
  readonly reload: Effect.Effect<void>;
  readonly loadMore: Effect.Effect<void>;
  readonly select: (event: AdminAuditEvent) => Effect.Effect<void>;
  readonly closeEvent: Effect.Effect<void>;
  readonly setAction: (action: string) => Effect.Effect<void>;
  readonly setActorDraft: (email: string) => Effect.Effect<void>;
  /** Filters by the typed operator email (empty clears it). */
  readonly submitActor: Effect.Effect<void>;
  readonly clearFilters: Effect.Effect<void>;
}

/**
 * The Audit log, optionally narrowed for good to `fixed` (a User's page shows the events about that User). The
 * operator's own filters add to it.
 */
export const makeAuditLogModel = (fixed: AdminAuditFilters = {}) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const state = yield* SubscriptionRef.make<AuditLogState>({
      actorDraft: "",
      filters: {},
      list: { status: "loading" },
      selected: undefined,
    });
    const query = Effect.map(SubscriptionRef.get(state), ({ filters }) => ({
      ...filters,
      ...fixed,
    }));
    const loading = yield* FiberHandle.make();
    const paging = yield* FiberHandle.make();

    const setList = (change: (list: AuditLogList) => AuditLogList) =>
      SubscriptionRef.update(state, (current) => ({
        ...current,
        list: change(current.list),
      }));

    const load = Effect.gen(function* () {
      // A page still loading belongs to the list being replaced.
      yield* FiberHandle.clear(paging);
      yield* setList(() => ({ status: "loading" }));
      const filters = yield* query;
      yield* api.listAuditEvents({ ...filters, limit: auditPageSize }).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures
              .read(error, messages.admin_audit_load_error())
              .pipe(
                Effect.flatMap((message) =>
                  message ? setList(() => ({ status: "error", message })) : Effect.void
                )
              ),
          onSuccess: (page) =>
            setList(() => ({
              status: "ready",
              events: page.data,
              hasMore: page.hasMore,
              loadingMore: false,
              ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
            })),
        })
      );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    /** Reads the list again when the filters change. */
    const applyFilters = (change: (filters: AdminAuditFilters) => AdminAuditFilters) =>
      Effect.gen(function* () {
        const previous = yield* SubscriptionRef.getAndUpdate(state, (current) => ({
          ...current,
          filters: change(current.filters),
        }));
        const { filters } = yield* SubscriptionRef.get(state);
        if (JSON.stringify(previous.filters) !== JSON.stringify(filters)) yield* reload;
      });

    const nextPage = (cursor: string) =>
      Effect.flatMap(query, (filters) =>
        api.listAuditEvents({ ...filters, cursor, limit: auditPageSize })
      ).pipe(
        Effect.matchEffect({
          onFailure: (error) => {
            // The cursor expired: start again from the newest page.
            if (error instanceof AdminApiError && error.code === "invalid_cursor") {
              return reload;
            }
            return failures
              .read(error, messages.admin_audit_load_more_error())
              .pipe(
                Effect.flatMap((message) =>
                  message
                    ? setList((list) =>
                        list.status === "ready"
                          ? { ...list, loadMoreError: message, loadingMore: false }
                          : list
                      )
                    : Effect.void
                )
              );
          },
          onSuccess: (page) =>
            setList((list) => {
              if (list.status !== "ready" || list.nextCursor !== cursor) return list;
              return {
                status: "ready",
                events: [...list.events, ...page.data],
                hasMore: page.hasMore,
                loadingMore: false,
                ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
              };
            }),
        })
      );

    const loadMore = Effect.gen(function* () {
      const { list } = yield* SubscriptionRef.get(state);
      if (
        list.status !== "ready" ||
        list.loadingMore ||
        !list.hasMore ||
        !list.nextCursor
      ) {
        return;
      }
      const cursor = list.nextCursor;
      yield* setList(() => ({ ...list, loadMoreError: undefined, loadingMore: true }));
      yield* FiberHandle.run(paging, nextPage(cursor));
    });

    const model: AuditLogModel = {
      state,
      reload,
      loadMore,
      select: (event) =>
        SubscriptionRef.update(state, (current) => ({ ...current, selected: event })),
      closeEvent: SubscriptionRef.update(state, (current) => ({
        ...current,
        selected: undefined,
      })),
      setAction: (action) =>
        applyFilters((filters) => withFilter(filters, "action", action)),
      setActorDraft: (actorDraft) =>
        SubscriptionRef.update(state, (current) => ({ ...current, actorDraft })),
      submitActor: Effect.gen(function* () {
        const { actorDraft } = yield* SubscriptionRef.get(state);
        yield* applyFilters((filters) =>
          withFilter(filters, "actorEmail", actorDraft.trim())
        );
      }),
      clearFilters: Effect.gen(function* () {
        yield* SubscriptionRef.update(state, (current) => ({
          ...current,
          actorDraft: "",
        }));
        yield* applyFilters(() => ({}));
      }),
    };
    return model;
  });

function withFilter(
  filters: AdminAuditFilters,
  key: keyof AdminAuditFilters,
  value: string
): AdminAuditFilters {
  const { [key]: _removed, ...rest } = filters;
  return value ? { ...rest, [key]: value } : rest;
}
