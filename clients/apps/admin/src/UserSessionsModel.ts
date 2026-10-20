// A user's login Sessions: filtered pages and the audited revocations.
import { Clock, Effect, FiberHandle, SubscriptionRef } from "effect";
import {
  AdminApi,
  AdminApiError,
  type AdminRequestError,
  type AdminSession,
  type AdminSessionFilters,
  type AdminUser,
} from "./adminApi";
import { makeConfirmation, makeFailures, type Confirmation } from "./adminModel";
import { messages } from "@comma/i18n";

const sessionPageSize = 20;

/** What the list shows first: valid Sessions, the most recently used first. */
export const defaultSessionFilters: AdminSessionFilters = {
  status: "active",
  clientKind: "all",
  sort: "last_seen_at",
};

export type UserSessionsList =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | {
      readonly status: "ready";
      readonly hasMore: boolean;
      readonly loadMoreError: string | undefined;
      readonly loadingMore: boolean;
      readonly nextCursor: string | undefined;
      /** When the list was last read (epoch seconds): Sessions expired by then show as expired. */
      readonly now: number;
      readonly sessions: ReadonlyArray<AdminSession>;
    };

export interface UserSessionsState {
  readonly filters: AdminSessionFilters;
  readonly list: UserSessionsList;
  readonly notice: string | undefined;
}

export interface UserSessionsModel {
  readonly state: SubscriptionRef.SubscriptionRef<UserSessionsState>;
  readonly confirmation: Confirmation;
  readonly reload: Effect.Effect<void>;
  readonly loadMore: Effect.Effect<void>;
  readonly setFilters: (filters: AdminSessionFilters) => Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly reviewRevoke: (session: AdminSession) => Effect.Effect<void>;
  readonly reviewRevokeAll: Effect.Effect<void>;
}

const metadata = (expected: string, key: string, reason: string) => ({
  confirmation: expected,
  idempotencyKey: key,
  reason,
});

export type SessionStatus = "active" | "expired" | "revoked";

export function sessionStatus(session: AdminSession, now: number): SessionStatus {
  if (session.revoked_at) return "revoked";
  if (session.expires_at <= now) return "expired";
  return "active";
}

export function sessionDeviceLabel(session: AdminSession) {
  if (session.device_label?.trim()) return session.device_label.trim();
  switch (session.client_kind) {
    case "web":
      return messages.admin_device_web();
    case "electron":
      return "Comma Desktop";
    case "android":
      return "Comma Android app";
    case "ios":
      return "Comma on iPhone";
    case "watch":
      return "Comma on Apple Watch";
    case "api":
      return messages.admin_device_api();
    case "ssh":
      return "Comma SSH";
    default:
      return messages.admin_device_unknown();
  }
}

const nowSeconds = Effect.map(Clock.currentTimeMillis, (millis) =>
  Math.floor(millis / 1_000)
);

export const makeUserSessionsModel = (user: AdminUser) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const state = yield* SubscriptionRef.make<UserSessionsState>({
      filters: defaultSessionFilters,
      list: { status: "loading" },
      notice: undefined,
    });
    const loading = yield* FiberHandle.make();

    const update = (change: (current: UserSessionsState) => UserSessionsState) =>
      SubscriptionRef.update(state, change);
    const updateReady = (
      change: (
        current: Extract<UserSessionsList, { status: "ready" }>
      ) => UserSessionsList
    ) =>
      update((current) =>
        current.list.status === "ready"
          ? { ...current, list: change(current.list) }
          : current
      );

    const load = Effect.gen(function* () {
      const { filters } = yield* SubscriptionRef.get(state);
      yield* update((current) => ({ ...current, list: { status: "loading" } }));
      yield* api.listUserSessions(user.id, { limit: sessionPageSize, ...filters }).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures.read(error, messages.admin_sessions_load_error()).pipe(
              Effect.flatMap((message) =>
                message
                  ? update((current) => ({
                      ...current,
                      list: { status: "error", message },
                    }))
                  : Effect.void
              )
            ),
          onSuccess: (page) =>
            Effect.gen(function* () {
              const now = yield* nowSeconds;
              yield* update((current) => ({
                ...current,
                list: {
                  status: "ready",
                  hasMore: page.hasMore,
                  loadMoreError: undefined,
                  loadingMore: false,
                  nextCursor: page.nextCursor,
                  now,
                  sessions: page.data,
                },
              }));
            }),
        })
      );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    const fetchMore = (cursor: string, filters: AdminSessionFilters) =>
      api
        .listUserSessions(user.id, { cursor, limit: sessionPageSize, ...filters })
        .pipe(
          Effect.matchEffect({
            onFailure: (error) => {
              // A cursor the server no longer accepts starts the list again from its first page.
              if (error instanceof AdminApiError && error.code === "invalid_cursor")
                return load;
              return failures
                .read(error, messages.admin_sessions_load_more_error())
                .pipe(
                  Effect.flatMap((message) =>
                    message
                      ? updateReady((list) => ({
                          ...list,
                          loadMoreError: message,
                          loadingMore: false,
                        }))
                      : Effect.void
                  )
                );
            },
            onSuccess: (page) =>
              Effect.gen(function* () {
                const now = yield* nowSeconds;
                yield* updateReady((list) => ({
                  status: "ready",
                  hasMore: page.hasMore,
                  loadMoreError: undefined,
                  loadingMore: false,
                  nextCursor: page.nextCursor,
                  now,
                  sessions: [...list.sessions, ...page.data],
                }));
              }),
          })
        );

    const loadMore = Effect.gen(function* () {
      const { filters, list } = yield* SubscriptionRef.get(state);
      if (
        list.status !== "ready" ||
        list.loadingMore ||
        !list.hasMore ||
        !list.nextCursor
      ) {
        return;
      }
      const cursor = list.nextCursor;
      yield* updateReady((current) => ({
        ...current,
        loadMoreError: undefined,
        loadingMore: true,
      }));
      yield* FiberHandle.run(loading, fetchMore(cursor, filters));
    });

    const command = <A>(effect: Effect.Effect<A, AdminRequestError>) =>
      effect.pipe(
        Effect.catch((error) =>
          failures
            .command(error)
            .pipe(Effect.flatMap((message) => Effect.fail(message)))
        )
      );

    const complete = (message: string) =>
      Effect.gen(function* () {
        yield* update((current) => ({ ...current, notice: message }));
        yield* reload;
      });

    const revokeAllExpected = `revoke-all-sessions:${user.id}`;
    const model: UserSessionsModel = {
      state,
      confirmation,
      reload,
      loadMore,
      setFilters: (filters) =>
        Effect.gen(function* () {
          yield* update((current) => ({ ...current, filters }));
          yield* reload;
        }),
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      reviewRevoke: (session) => {
        const expected = `revoke-session:${session.id}`;
        return confirmation.open({
          destructive: true,
          explanation: messages.admin_session_signed_out({
            device: sessionDeviceLabel(session),
          }),
          keyPrefix: "revoke-session",
          run: (key, reason) =>
            Effect.gen(function* () {
              yield* command(
                api.revokeUserSession(
                  user.id,
                  session.id,
                  metadata(expected, key, reason)
                )
              );
              yield* complete(
                messages.admin_session_revoked({ device: sessionDeviceLabel(session) })
              );
            }),
          title: messages.admin_revoke_session_title(),
        });
      },
      reviewRevokeAll: confirmation.open({
        destructive: true,
        explanation: messages.admin_signed_out_everywhere({
          account: user.email ?? user.id,
        }),
        keyPrefix: "revoke-all-sessions",
        run: (key, reason) =>
          Effect.gen(function* () {
            const result = yield* command(
              api.revokeAllUserSessions(
                user.id,
                metadata(revokeAllExpected, key, reason)
              )
            );
            yield* complete(
              result.revoked_count === 1
                ? messages.admin_revoked_count_one()
                : messages.admin_revoked_count({ count: result.revoked_count })
            );
          }),
        title: messages.admin_revoke_all_review_title(),
        typed: user.email ?? user.id,
      }),
    };
    return model;
  });
