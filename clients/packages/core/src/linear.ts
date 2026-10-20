// Linear in Settings › Channels: a workspace's link (its person's Linear account in one organization where Comma is
// installed as an agent), the connect under way (the UI opens the address this answers; the core then reads the link
// every 1.5 s until a new one shows) and its settings. What is under way is the core's, not a page's: leaving
// Channels does not stop a connect, and coming back shows it.
//
// Bounds, per workspace whose topic is live: one change at a time; a connect reads the link at most 200 times (about
// 5 minutes), one read at a time, without the Worker list until it lands, and stops when it lands, is cancelled, the
// account changes or 3 reads in a row fail. Kept in memory only.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect, type Fiber } from "effect";
import { route } from "./api.ts";
import {
  linearConnectAttemptSchema,
  linearDisconnectSchema,
  linearIntegrationSchema,
  linearMemberSchema,
} from "./comma/schemas.ts";
import type { LinearIntegration, LinearMember, LinearValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const CHECK_EVERY_MS = 1_500;
const MAX_CHECKS = 200;
const MAX_FAILED_CHECKS = 3;
const POLICIES = new Set(["unchanged", "in_review", "done"]);

const linearPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/linear`;

type State = {
  state: LinearIntegration | null;
  attempt: string | null;
  checks: number;
  error: boolean;
  busy: boolean;
  install: Fiber.Fiber<unknown, unknown> | null;
  reading: Fiber.Fiber<unknown, unknown> | null;
};

const params = {
  string(raw: unknown, name: string, max = 64): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

/** Whether `next` shows a link the connect made: one where there was none, or a changed one, with Comma installed. */
function linked(next: LinearIntegration, before: LinearMember | null): boolean {
  const member = next.member;
  if (!member || !next.installation || next.installation.revoked) return false;
  return !before || member.id !== before.id || member.updated_at !== before.updated_at;
}

const busy = () => new CoreError("busy", "Another change is under way.");

export class Linear {
  readonly #ctx: Ctx;
  readonly #states = new Map<string, State>();
  #accountKey: string | null = null;

  static #empty(): State {
    return {
      state: null,
      attempt: null,
      checks: 0,
      error: false,
      busy: false,
      install: null,
      reading: null,
    };
  }

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("linear", {
      start: (topic) => {
        const workspace = topic.workspace as string;
        if (!this.#states.has(workspace)) this.#states.set(workspace, Linear.#empty());
        this.#read(workspace);
      },
      stop: (topic) => {
        // An install under way goes on; only the reads of a page that left stop.
        const s = this.#states.get(topic.workspace as string);
        if (s && !s.install) {
          if (s.reading) ctx.runner.interrupt(s.reading);
          this.#states.delete(topic.workspace as string);
        }
      },
      compute: (topic): Value => ({ ok: this.#value(topic.workspace as string) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const [workspace, s] of this.#states) {
        if (s.install) ctx.runner.interrupt(s.install);
        if (s.reading) ctx.runner.interrupt(s.reading);
        this.#states.set(workspace, Linear.#empty());
        this.#invalidate(workspace);
        if (this.#live(workspace)) this.#read(workspace);
      }
    });

    kernel.calls({
      "linear.refresh": {
        run: (p) =>
          Effect.sync(() => this.#read(params.string(p, "workspace"))).pipe(
            Effect.as(null)
          ),
      },
      "linear.connect": {
        doing: true,
        run: (p) =>
          this.#connect(params.string(p, "workspace"), params.string(p, "environment")),
      },
      "linear.cancel": {
        run: (p) =>
          this.#cancel(
            params.string(p, "workspace"),
            (p as { closed?: unknown } | null)?.closed === true
          ),
      },
      "linear.disconnect": {
        doing: true,
        run: (p) =>
          this.#disconnect(
            params.string(p, "workspace"),
            (p as { scope?: unknown } | null)?.scope === "organization"
          ),
      },
      "linear.updateSettings": {
        doing: true,
        run: (p) => this.#updateSettings(params.string(p, "workspace"), p),
      },
    });
  }

  #live(workspace: string): boolean {
    return this.#ctx.kernel.store
      .liveTopics()
      .some((t) => t.topic === "linear" && t.workspace === workspace);
  }

  #invalidate(workspace: string): void {
    this.#ctx.kernel.store.invalidate({ topic: "linear", workspace } as Topic);
  }

  #value(workspace: string): LinearValue {
    const s = this.#states.get(workspace);
    return {
      state: s?.state ?? null,
      attempt: s?.attempt ?? null,
      checks: s?.checks ?? 0,
      error: s?.error ?? false,
      busy: s?.busy ?? false,
    };
  }

  #set(workspace: string, change: Partial<State>): void {
    const s = this.#states.get(workspace);
    if (!s) return;
    Object.assign(s, change);
    this.#invalidate(workspace);
  }

  #account() {
    return this.#ctx.session.account();
  }

  #get(workspace: string) {
    const ctx = this.#ctx;
    return this.#account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, "GET", linearPath(workspace), linearIntegrationSchema)
      )
    );
  }

  /** Reads the link, unless a change is under way (it reads it itself). */
  #read(workspace: string): void {
    const s = this.#states.get(workspace);
    if (!s || s.busy || s.reading) return;
    this.#set(workspace, { error: false });
    s.reading = this.#ctx.runner.fork(
      this.#get(workspace).pipe(
        Effect.tap((state) => Effect.sync(() => this.#set(workspace, { state }))),
        Effect.catch(() => Effect.sync(() => this.#set(workspace, { error: true }))),
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#states.get(workspace) === s) s.reading = null;
          })
        )
      )
    );
  }

  #stopInstall(workspace: string): void {
    const s = this.#states.get(workspace);
    if (s?.install) this.#ctx.runner.interrupt(s.install);
    if (s) s.install = null;
  }

  #connect(
    workspace: string,
    environment: string
  ): Effect.Effect<{ authorizationUrl: string }, CoreError> {
    return Effect.suspend(() => {
      const s = this.#states.get(workspace);
      if (!s) return Effect.fail(CoreError.invalid("Linear is not shown"));
      if (s.busy) return Effect.fail(busy());
      const before = s.state?.member ?? null;
      this.#set(workspace, { busy: true, error: false });
      const ctx = this.#ctx;
      return this.#account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "POST",
            `${linearPath(workspace)}/connect`,
            linearConnectAttemptSchema,
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
              new CoreError("bad_response", "Linear connect state is missing")
            );
          this.#set(workspace, { attempt: state, checks: 0 });
          s.install = ctx.runner.fork(this.#follow(workspace, before));
          return Effect.succeed({ authorizationUrl: attempt.authorization_url });
        }),
        Effect.tapError(() =>
          Effect.sync(() => this.#set(workspace, { busy: false, error: true }))
        )
      );
    });
  }

  /**
   * Reads the link until the connect lands it, then reads it once more with the Workers. After 200 reads, or 3
   * failed reads in a row, it is a failure the person can cancel.
   */
  #follow(workspace: string, before: LinearMember | null): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      let failed = 0;
      for (let check = 0; check < MAX_CHECKS; check += 1) {
        const read = yield* this.#get(workspace).pipe(Effect.orElseSucceed(() => null));
        if (!read) {
          failed += 1;
          if (failed >= MAX_FAILED_CHECKS) {
            this.#set(workspace, { busy: false, error: true });
            return;
          }
          this.#set(workspace, { checks: check + 1 });
          yield* Effect.sleep(CHECK_EVERY_MS);
          continue;
        }
        failed = 0;
        const state = read;
        if (linked(state, before)) {
          this.#set(workspace, {
            state,
            attempt: null,
            busy: false,
            checks: check + 1,
          });
          return;
        }
        this.#set(workspace, { state, checks: check + 1 });
        yield* Effect.sleep(CHECK_EVERY_MS);
      }
      this.#set(workspace, { busy: false, error: true });
    }).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          const s = this.#states.get(workspace);
          if (s) s.install = null;
          if (!this.#live(workspace)) this.#states.delete(workspace);
        })
      )
    );
  }

  /** Stops following the connect under way; the server lets its state expire. `closed`: its window was closed. */
  #cancel(workspace: string, closed: boolean): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const s = this.#states.get(workspace);
      if (!s || !s.attempt) return Effect.succeed(null);
      this.#stopInstall(workspace);
      this.#set(workspace, { attempt: null, busy: false, error: closed });
      if (!closed) this.#read(workspace);
      return Effect.succeed(null);
    });
  }

  /** Removes this workspace's link, or with `organization` Comma from the organization (the installer only). */
  #disconnect(
    workspace: string,
    organization: boolean
  ): Effect.Effect<null, CoreError> {
    const path = organization
      ? `${linearPath(workspace)}?scope=organization`
      : linearPath(workspace);
    return this.#change(workspace, (account) =>
      this.#ctx.api
        .request(account, "DELETE", path, linearDisconnectSchema, {})
        .pipe(Effect.andThen(this.#get(workspace)))
    );
  }

  #updateSettings(workspace: string, raw: unknown): Effect.Effect<null, CoreError> {
    const p = (raw as Record<string, unknown> | null) ?? {};
    const body: Record<string, unknown> = {};
    if ("completion_state_policy" in p) {
      const policy = p.completion_state_policy;
      if (typeof policy !== "string" || !POLICIES.has(policy))
        throw CoreError.invalid("completion_state_policy is not a policy");
      body.completion_state_policy = policy;
    }
    if (Object.keys(body).length === 0) throw CoreError.invalid("nothing to change");
    return this.#change(workspace, (account) =>
      this.#ctx.api
        .request(account, "PATCH", linearPath(workspace), linearMemberSchema, body)
        .pipe(Effect.andThen(this.#get(workspace)))
    );
  }

  /** One change at a time; it ends with the link read again. A failure shows until the next read. */
  #change(
    workspace: string,
    work: (
      account: Parameters<Ctx["api"]["request"]>[0]
    ) => Effect.Effect<LinearIntegration, CoreError>
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const s = this.#states.get(workspace);
      if (!s) return Effect.fail(CoreError.invalid("Linear is not shown"));
      if (s.busy) return Effect.fail(busy());
      this.#set(workspace, { busy: true, error: false });
      return this.#account().pipe(
        Effect.flatMap((account) => work(account)),
        Effect.tap((state) =>
          Effect.sync(() => this.#set(workspace, { state, attempt: null }))
        ),
        Effect.tapError(() => Effect.sync(() => this.#set(workspace, { error: true }))),
        Effect.ensuring(Effect.sync(() => this.#set(workspace, { busy: false }))),
        Effect.as(null)
      );
    });
  }
}
