// Overview: how many accounts there are and how many signed up lately, how much of today's guest allowance is used,
// and the latest audited operations. Each part reads on its own, so one failing read leaves the others shown.
import { messages } from "@comma/i18n";
import { Effect, SubscriptionRef } from "effect";
import {
  AdminApi,
  type AdminAuditEvent,
  type AdminUserStats,
  type GuestModePolicy,
} from "./adminApi";
import { AdminShellLinks, makeFailures } from "./adminModel";
import type { AdminSection } from "./adminNavigation";

export const recentEventCount = 6;

export type Loaded<A> =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | { readonly status: "ready"; readonly value: A };

export interface OverviewState {
  readonly events: Loaded<ReadonlyArray<AdminAuditEvent>>;
  readonly guest: Loaded<GuestModePolicy>;
  readonly stats: Loaded<AdminUserStats>;
}

export interface OverviewModel {
  readonly state: SubscriptionRef.SubscriptionRef<OverviewState>;
  readonly reload: Effect.Effect<void>;
  readonly open: (section: AdminSection) => Effect.Effect<void>;
  readonly openUser: (userId: string) => Effect.Effect<void>;
}

export const makeOverviewModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const links = yield* AdminShellLinks;
  const failures = yield* makeFailures;
  const state = yield* SubscriptionRef.make<OverviewState>({
    events: { status: "loading" },
    guest: { status: "loading" },
    stats: { status: "loading" },
  });

  const read = <K extends keyof OverviewState, A>(
    key: K,
    request: Effect.Effect<A, unknown>,
    fallback: string,
    wrap: (value: A) => OverviewState[K]
  ) =>
    request.pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures.read(error, fallback).pipe(
            Effect.flatMap((message) =>
              message
                ? SubscriptionRef.update(state, (current) => ({
                    ...current,
                    [key]: { status: "error", message },
                  }))
                : Effect.void
            )
          ),
        onSuccess: (value) =>
          SubscriptionRef.update(state, (current) => ({
            ...current,
            [key]: wrap(value),
          })),
      })
    );

  const reload = Effect.gen(function* () {
    yield* SubscriptionRef.set(state, {
      events: { status: "loading" },
      guest: { status: "loading" },
      stats: { status: "loading" },
    });
    yield* Effect.all(
      [
        read("stats", api.getUserStats, messages.admin_stats_load_error(), (value) => ({
          status: "ready" as const,
          value,
        })),
        read("guest", api.getGuestMode, messages.admin_guest_load_error(), (value) => ({
          status: "ready" as const,
          value,
        })),
        read(
          "events",
          api.listAuditEvents({ limit: recentEventCount }),
          messages.admin_audit_load_error(),
          (page) => ({ status: "ready" as const, value: page.data })
        ),
      ],
      { concurrency: "unbounded", discard: true }
    );
  });
  yield* Effect.forkScoped(reload);

  const model: OverviewModel = {
    state,
    reload,
    open: links.select,
    openUser: links.openUser,
  };
  return model;
});
