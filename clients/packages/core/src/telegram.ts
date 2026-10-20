// Telegram in Settings › Channels: the account's one workspace's connection, its official login (the UI opens the
// address this answers; the core then reads the connection every 1.5 s until a new link shows) and its disconnect.
// What is under way is the core's, not a page's: leaving Channels does not stop a login, and coming back shows it.
//
// Bounds: one change at a time per core; a login reads the connection at most 200 times (about 5 minutes), one read
// at a time, and stops when it links, is cancelled or the account changes. Kept in memory only.
import { CoreError, Priority, type Value } from "@comma/core-kernel";
import { Effect, type Fiber } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import {
  telegramConnectAttemptSchema,
  telegramDisconnectSchema,
  telegramIntegrationSchema,
} from "./comma/schemas.ts";
import type { TelegramIntegration, TelegramValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const CHECK_EVERY_MS = 1_500;
const TOPIC = { topic: "telegram" };

const telegramPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/telegram`;

/** Whether `next` shows a link the login made: a link where there was none, or another one. */
function linked(
  next: TelegramIntegration,
  before: TelegramIntegration["link"]
): boolean {
  const link = next.link;
  if (!link || next.connection_active === false) return false;
  return (
    !before ||
    link.connection_id !== before.connection_id ||
    link.telegram_user_id !== before.telegram_user_id ||
    link.updated_at !== before.updated_at
  );
}

export class Telegram {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  #value: TelegramValue = Telegram.#empty();
  #login: Fiber.Fiber<unknown, unknown> | null = null;
  #reading: Fiber.Fiber<unknown, unknown> | null = null;
  #accountKey: string | null = null;

  static #empty(): TelegramValue {
    return {
      workspace: null,
      state: null,
      attempt: null,
      checks: 0,
      error: false,
      busy: false,
    };
  }

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    const { kernel } = ctx;
    kernel.source("telegram", {
      // A page coming to Channels reads it; what is under way goes on whether or not a page shows it.
      start: () => this.#read(),
      stop: () => {},
      compute: (): Value => ({ ok: this.#value }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#stopLogin();
      if (this.#reading) ctx.runner.interrupt(this.#reading);
      this.#reading = null;
      this.#value = Telegram.#empty();
      kernel.store.invalidate(TOPIC);
      if (kernel.store.liveTopics().some((t) => t.topic === "telegram")) this.#read();
    });

    kernel.calls({
      "telegram.refresh": {
        run: () => Effect.sync(() => this.#read()).pipe(Effect.as(null)),
      },
      "telegram.connect": {
        doing: true,
        run: (p) => {
          const environment = (p as { environment?: unknown } | null)?.environment;
          if (
            typeof environment !== "string" ||
            !environment ||
            environment.length > 64
          )
            throw CoreError.invalid("environment is required");
          return this.#connect(environment);
        },
      },
      "telegram.cancel": {
        run: (p) => this.#cancel((p as { closed?: unknown } | null)?.closed === true),
      },
      "telegram.disconnect": { doing: true, run: () => this.#disconnect() },
    });
  }

  #set(change: Partial<TelegramValue>): void {
    this.#value = { ...this.#value, ...change };
    this.#ctx.kernel.store.invalidate(TOPIC);
  }

  #account() {
    return this.#ctx.session.account();
  }

  #get(workspace: string) {
    const ctx = this.#ctx;
    return this.#account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          "GET",
          telegramPath(workspace),
          telegramIntegrationSchema
        )
      )
    );
  }

  /** Which workspace: the account's only one (Comma v1 has one per account; anything else is shown as a failure). */
  #workspace(): Effect.Effect<string, CoreError> {
    return this.#workspaces.refresh(Priority.shown).pipe(
      Effect.andThen(this.#account()),
      Effect.flatMap((account) => {
        const list = this.#workspaces.list(account) ?? [];
        return list.length === 1
          ? Effect.succeed(list[0]!.id)
          : Effect.fail(
              new CoreError(
                "workspace_unavailable",
                "Telegram needs exactly one workspace."
              )
            );
      }),
      Effect.tap((workspace) => Effect.sync(() => this.#set({ workspace })))
    );
  }

  /** Reads the workspace and its connection, unless a change is under way (it reads them itself). */
  #read(): void {
    if (this.#value.busy || this.#reading) return;
    this.#set({ error: false });
    this.#reading = this.#ctx.runner.fork(
      this.#workspace().pipe(
        Effect.flatMap((workspace) => this.#get(workspace)),
        Effect.tap((state) => Effect.sync(() => this.#set({ state }))),
        Effect.catch(() => Effect.sync(() => this.#set({ error: true }))),
        Effect.ensuring(Effect.sync(() => (this.#reading = null)))
      )
    );
  }

  #stopLogin(): void {
    if (this.#login) this.#ctx.runner.interrupt(this.#login);
    this.#login = null;
  }

  #connect(
    environment: string
  ): Effect.Effect<{ authorizationUrl: string }, CoreError> {
    return Effect.suspend(() => {
      const workspace = this.#value.workspace;
      if (this.#value.busy)
        return Effect.fail(new CoreError("busy", "Another change is under way."));
      if (!workspace) return Effect.fail(CoreError.invalid("no workspace"));
      const before = this.#value.state?.link ?? null;
      this.#set({ busy: true, error: false });
      const ctx = this.#ctx;
      return this.#account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "POST",
            `${telegramPath(workspace)}/connect`,
            telegramConnectAttemptSchema,
            { environment }
          )
        ),
        Effect.flatMap((attempt) => {
          let state: string | null = null;
          try {
            state = new URL(attempt.authorization_url).searchParams.get("state");
          } catch {
            state = null;
          }
          if (!state)
            return Effect.fail(
              new CoreError("bad_response", "Telegram login state is missing")
            );
          this.#set({ attempt: state, checks: 0 });
          this.#login = ctx.runner.fork(this.#follow(workspace, before));
          return Effect.succeed({ authorizationUrl: attempt.authorization_url });
        }),
        Effect.tapError(() =>
          Effect.sync(() => this.#set({ busy: false, error: true }))
        )
      );
    });
  }

  /** Reads the connection until the login links it; after `limits.telegramLoginReads` reads (200) it is a failure the person can cancel. */
  #follow(workspace: string, before: TelegramIntegration["link"]): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      for (let check = 0; check < this.#ctx.limits.telegramLoginReads; check += 1) {
        const state = yield* this.#get(workspace).pipe(
          Effect.orElseSucceed(() => null)
        );
        if (!state) {
          this.#set({ busy: false, error: true });
          return;
        }
        if (linked(state, before)) {
          this.#set({ state, attempt: null, busy: false, checks: check + 1 });
          return;
        }
        this.#set({ state, checks: check + 1 });
        yield* Effect.sleep(CHECK_EVERY_MS);
      }
      this.#set({ busy: false, error: true });
    }).pipe(Effect.ensuring(Effect.sync(() => (this.#login = null))));
  }

  /** Stops the login under way and cancels it with the server; `closed`: its window was closed, which is a failure. */
  #cancel(closed: boolean): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const { workspace, attempt } = this.#value;
      if (!workspace || !attempt) return Effect.succeed(null);
      this.#stopLogin();
      this.#set({ busy: true, error: closed });
      const ctx = this.#ctx;
      return this.#account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "DELETE",
            `${telegramPath(workspace)}/connect`,
            z.object({ cancelled: z.boolean() }),
            { state: attempt }
          )
        ),
        Effect.andThen(closed ? Effect.succeed(null) : this.#get(workspace)),
        Effect.tap((state) =>
          Effect.sync(() => this.#set({ attempt: null, ...(state ? { state } : {}) }))
        ),
        Effect.tapError(() => Effect.sync(() => this.#set({ error: true }))),
        Effect.ensuring(Effect.sync(() => this.#set({ busy: false }))),
        Effect.as(null)
      );
    });
  }

  #disconnect(): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const workspace = this.#value.workspace;
      if (this.#value.busy)
        return Effect.fail(new CoreError("busy", "Another change is under way."));
      if (!workspace) return Effect.fail(CoreError.invalid("no workspace"));
      this.#set({ busy: true, error: false });
      const ctx = this.#ctx;
      return this.#account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "DELETE",
            telegramPath(workspace),
            telegramDisconnectSchema,
            {}
          )
        ),
        Effect.andThen(this.#get(workspace)),
        Effect.tap((state) => Effect.sync(() => this.#set({ state, attempt: null }))),
        Effect.tapError(() => Effect.sync(() => this.#set({ error: true }))),
        Effect.ensuring(Effect.sync(() => this.#set({ busy: false }))),
        Effect.as(null)
      );
    });
  }
}
