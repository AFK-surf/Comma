// Settings › Signed-in devices (`accountSessions`): the account's sessions that are still open, this one first, then
// the most recently active. Read when a surface shows it and on `accountSessions.refresh`. Signing out another
// session, or every other one, takes its row away at once and reads the list again. A paired Apple Watch is one more
// session: the iPhone asks for a one-time pairing (`accountSessions.pairWatch`) that the watch exchanges for its own.
//
// Bounds: one read in flight per shown list, at most five pages of 100; each change is one request, then one read; a
// pairing is one request.
import { CoreError, Priority, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import type { AccountSession, AccountSessionsValue } from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";

const PAGES = 5;
const currentSchema = z.object({ session_id: z.string() });
const watchPairingSchema = z.object({
  pairing_id: z.string().min(1).max(256),
  pairing_secret: z.string().min(1).max(1_024),
  expires_at: z.number(),
});
const pageSchema = z.object({
  data: z.array(
    z.object({
      id: z.string().min(1),
      device_label: z.string().nullish(),
      client_kind: z.string().nullish(),
      client_platform: z.string().nullish(),
      authenticated_at: z.number().nullish(),
      last_seen_at: z.number().nullish(),
      expires_at: z.number().nullish(),
      revoked_at: z.unknown().optional(),
    })
  ),
  has_more: z.boolean().optional(),
  next_cursor: z.string().nullish(),
});

export class AccountSessions {
  readonly #ctx: Ctx;
  readonly #live: Live;
  #value: AccountSessionsValue = { status: "loading", sessions: [] };
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("accountSessions", {
      start: (topic) => this.#live.run(topic, this.#quietRead(Priority.shown)),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.#value }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#live.stopAll();
      this.#set({ status: "loading", sessions: [] });
      for (const topic of kernel.store.liveTopics())
        if (topic.topic === "accountSessions")
          this.#live.run(topic, this.#quietRead(Priority.shown));
    });
    kernel.calls({
      "accountSessions.refresh": {
        run: () => this.#read(Priority.asked).pipe(Effect.as(null)),
      },
      "accountSessions.revoke": {
        doing: true,
        run: (p) => {
          const id = (p as { id?: unknown } | null)?.id;
          if (typeof id !== "string" || id === "" || id.length > 256)
            throw CoreError.invalid("id is required");
          return this.#change(
            (rows) => rows.filter((row) => row.id !== id),
            (account) =>
              ctx.api
                .request(
                  account,
                  "DELETE",
                  route`/v1/comma/auth/sessions/${id}`,
                  z.unknown()
                )
                .pipe(
                  Effect.catchIf(
                    (e) => e.status === 404,
                    () => Effect.void
                  )
                )
          ).pipe(Effect.as(null));
        },
      },
      "accountSessions.pairWatch": {
        doing: true,
        run: () =>
          ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                "/v1/comma/auth/watch/pairing",
                watchPairingSchema,
                {}
              )
            ),
            Effect.map((pairing) => ({
              pairingId: pairing.pairing_id,
              pairingSecret: pairing.pairing_secret,
              expiresAt: pairing.expires_at,
            }))
          ),
      },
      "accountSessions.revokeOthers": {
        doing: true,
        run: () =>
          this.#change(
            (rows) => rows.filter((row) => row.current),
            (account) =>
              ctx.api
                .request(
                  account,
                  "POST",
                  "/v1/comma/auth/sessions/revoke-all",
                  z.object({ revoked_count: z.number().optional() }),
                  // Anything but `true` ends this session too.
                  { keep_current: true }
                )
                .pipe(Effect.map((answer) => answer.revoked_count ?? 0))
          ),
      },
    });
  }

  #set(value: AccountSessionsValue): void {
    this.#value = value;
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "accountSessions") store.invalidate(topic);
  }

  /** Shows the list without what is being signed out, sends the change, then reads the list again (either way). */
  #change<A>(
    without: (rows: AccountSession[]) => AccountSession[],
    send: (account: Account) => Effect.Effect<A, CoreError>
  ): Effect.Effect<A, CoreError> {
    return this.#ctx.session.account().pipe(
      Effect.tap(() =>
        Effect.sync(() =>
          this.#set({ ...this.#value, sessions: without(this.#value.sessions) })
        )
      ),
      Effect.flatMap(send),
      Effect.ensuring(this.#quietRead(Priority.asked))
    );
  }

  #quietRead(priority: number): Effect.Effect<void> {
    return this.#read(priority).pipe(Effect.ignore);
  }

  #read(priority: number): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const key = ctx.session.accountKey();
      const read = Effect.gen({ self: this }, function* () {
        const current = yield* ctx.api.request(
          account.value,
          "GET",
          "/v1/comma/auth/session",
          currentSchema
        );
        const rows: z.output<typeof pageSchema>["data"] = [];
        let cursor: string | null | undefined;
        for (let page = 0; page < PAGES; page++) {
          const query = new URLSearchParams({ limit: "100" });
          if (cursor) query.set("cursor", cursor);
          const answer = yield* ctx.api.request(
            account.value,
            "GET",
            `/v1/comma/auth/sessions?${query}`,
            pageSchema
          );
          rows.push(...answer.data);
          cursor = answer.next_cursor;
          if (!answer.has_more || !cursor) break;
        }
        if (ctx.session.accountKey() !== key) return;
        this.#set({
          status: "ready",
          sessions: openSessions(rows, current.session_id, ctx.now() / 1000),
        });
      });
      yield* ctx.scheduler
        .ask(API_LANE, `${account.value.dbName}:accountSessions`, priority, read)
        .pipe(
          Effect.tapError(() =>
            Effect.sync(() => {
              if (ctx.session.accountKey() === key && this.#value.status !== "ready")
                this.#set({ status: "error", sessions: [] });
            })
          )
        );
    });
  }
}

/** The sessions still open, once each: this one (`current`) first, then the most recently active. */
function openSessions(
  rows: z.output<typeof pageSchema>["data"],
  current: string,
  now: number
): AccountSession[] {
  const seen = new Set<string>();
  return rows
    .filter((row) => {
      if (row.revoked_at != null || (row.expires_at ?? Number.MAX_SAFE_INTEGER) <= now)
        return false;
      if (seen.has(row.id)) return false;
      seen.add(row.id);
      return true;
    })
    .map(
      (row): AccountSession => ({
        id: row.id,
        deviceLabel: row.device_label ?? null,
        clientKind: row.client_kind ?? null,
        clientPlatform: row.client_platform ?? null,
        authenticatedAt: row.authenticated_at ?? null,
        lastSeenAt: row.last_seen_at ?? null,
        current: row.id === current,
      })
    )
    .toSorted(
      (a, b) =>
        Number(b.current) - Number(a.current) ||
        (b.lastSeenAt ?? b.authenticatedAt ?? 0) -
          (a.lastSeenAt ?? a.authenticatedAt ?? 0)
    );
}
