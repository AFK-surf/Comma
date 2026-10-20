// The account's workspaces (kept on the device, `doc` "workspaces") and its default workspace while it is provisioned
// (the `onboardingWorkspace` topic: every workspace-scoped call the onboarding makes answers `workspace_provisioning`
// until it is ready).
//
// Bound of the bootstrap: one loop per core while the topic is live, one `POST /v1/comma/me/bootstrap` in flight, one
// request per `retry_after_seconds` clamped to 1–10 s (10 s after a failure without an answer), nothing after `ready`
// or a terminal answer.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import {
  pageSchema,
  type Workspace,
  workspaceBootstrapSchema,
  workspaceSchema,
} from "./comma/schemas.ts";
import type { OnboardingWorkspace, ResolvedWorkspace } from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import type { SessionLease } from "./host.ts";

export const WORKSPACES_DOC = "workspaces";
/** The account's meta key for the workspace the app works in (`workspace.select`). */
export const ACTIVE_WORKSPACE_META = "activeWorkspace";
/** Longest workspace id `workspace.select` keeps. */
const MAX_WORKSPACE_ID = 256;
export const ONBOARDING_WORKSPACE: Topic = { topic: "onboardingWorkspace" };

const MAX_RETRY_S = 10;
/** Answers that a later bootstrap cannot change: the session is gone, or the account has no workspace it may use. */
const TERMINAL = new Set([401, 403, 404]);

/** Whether a workspace can have plugins and the onboarding's calls: ready (or from before workspaces had a status). */
export function workspaceUsable(workspace: Pick<Workspace, "status">): boolean {
  return workspace.status === undefined || workspace.status === "ready";
}

export class Workspaces {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** The last read of the list failed with this, while nothing was read before. */
  #listFailure: CoreError | null = null;
  #bootstrap: OnboardingWorkspace = { status: "preparing" };
  readonly #listeners = new Set<() => void>();
  #accountKey: string | null = null;
  #lease: SessionLease | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    ctx.kernel.source("onboardingWorkspace", {
      start: () => this.#startBootstrap(),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.onboarding() }),
    });
    // The workspace a surface works in: `prefer` when the account has it, else the one the app works in
    // (`workspace.select`), else its first. Read again when shown.
    ctx.kernel.source("workspace", {
      start: (topic) =>
        this.#live.run(topic, this.refresh(Priority.shown).pipe(Effect.ignore)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#resolved(String(topic.prefer ?? "")) }),
    });
    ctx.kernel.calls({
      // The workspace the app works in from now on, on every window of this device; kept with the account, so a
      // sign-out forgets it.
      "workspace.select": {
        run: (p) => {
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          if (
            typeof workspace !== "string" ||
            !workspace ||
            workspace.length > MAX_WORKSPACE_ID
          )
            throw CoreError.invalid("workspace is required");
          return ctx.session.account().pipe(
            Effect.map((account) => {
              if (account.meta<string>(ACTIVE_WORKSPACE_META) !== workspace) {
                account.setMeta(ACTIVE_WORKSPACE_META, workspace);
                this.#changed();
              }
              return null;
            })
          );
        },
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key !== this.#accountKey) {
        // Another account (or none): nothing of the one before is shown or kept going.
        this.#accountKey = key;
        this.#listFailure = null;
        this.#bootstrap = { status: "preparing" };
        if (this.#live.live(ONBOARDING_WORKSPACE)) {
          this.#live.stop(ONBOARDING_WORKSPACE);
          this.#startBootstrap();
        }
      }
      const lease = ctx.session.lease();
      if (lease !== this.#lease) {
        this.#lease = lease;
        // One refresh on a new lease, including confirmation of a kept account. The list read started before
        // admission could not send a request. All live workspace views share the resulting account document.
        const shown = ctx.kernel.store
          .liveTopics()
          .find((topic) => topic.topic === "workspace");
        if (lease && shown)
          this.#live.run(shown, this.refresh(Priority.shown).pipe(Effect.ignore));
      }
      this.#changed();
    });
  }

  /** Told after the list or the onboarding's workspace changed. */
  onChange(listener: () => void): void {
    this.#listeners.add(listener);
  }

  /** The workspace a surface works in for `prefer` (none: the one the app works in), as the `workspace` topic says it. */
  resolve(prefer: string): ResolvedWorkspace {
    return this.#resolved(prefer);
  }

  #resolved(prefer: string): ResolvedWorkspace {
    const account = this.#ctx.session.current();
    const active = account?.meta<string>(ACTIVE_WORKSPACE_META) ?? "";
    const selected = prefer ? {} : { selected: active !== "" };
    const list = account ? this.list(account) : null;
    if (!list)
      return {
        status: this.#listFailure ? "error" : "loading",
        workspace: null,
        ...selected,
      };
    const workspace =
      list.find((w) => w.id === prefer) ?? list.find((w) => w.id === active) ?? list[0];
    return {
      status: "ready",
      workspace: workspace
        ? { id: workspace.id, groupId: workspace.group_id, name: workspace.name }
        : null,
      ...selected,
    };
  }

  #changed(): void {
    const { store } = this.#ctx.kernel;
    store.invalidate(ONBOARDING_WORKSPACE);
    for (const topic of store.liveTopics())
      if (topic.topic === "workspace") store.invalidate(topic);
    for (const listener of this.#listeners) listener();
  }

  /** The workspaces as last read; null when they never were. */
  list(account: Account): Workspace[] | null {
    return account.doc<Workspace[]>(WORKSPACES_DOC)?.value ?? null;
  }

  listFailure(): CoreError | null {
    return this.#listFailure;
  }

  /** Reads the list again (one read at a time; asked again while it runs, it runs once more after). */
  refresh(priority: number = Priority.shown): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${WORKSPACES_DOC}`,
          priority,
          ctx.api
            .request(
              account,
              "GET",
              "/v1/comma/workspaces",
              pageSchema(workspaceSchema)
            )
            .pipe(
              Effect.tap((page) =>
                Effect.sync(() => {
                  if (account.putDoc(WORKSPACES_DOC, page.data, ctx.now())) {
                    this.#listFailure = null;
                    this.#changed();
                  }
                })
              ),
              Effect.tapError((error) =>
                Effect.sync(() => {
                  if (account.closed || account.doc(WORKSPACES_DOC)) return;
                  this.#listFailure = error;
                  this.#changed();
                })
              ),
              Effect.asVoid
            )
        )
      )
    );
  }

  onboarding(): OnboardingWorkspace {
    return this.#bootstrap;
  }

  #setBootstrap(next: OnboardingWorkspace): void {
    this.#bootstrap = next;
    this.#changed();
  }

  #startBootstrap(): void {
    const ctx = this.#ctx;
    // A workspace found ready before is ready now: shown at once, and asked again.
    const known = ctx.session.current()?.meta<string>("onboardingWorkspace");
    if (known && this.#bootstrap.status === "preparing" && !this.#bootstrap.unreachable)
      this.#bootstrap = { status: "ready", workspaceId: known };
    this.#live.run(
      ONBOARDING_WORKSPACE,
      Effect.gen({ self: this }, function* () {
        for (;;) {
          let delayS = MAX_RETRY_S;
          // With no one signed in it waits: a session that comes starts it again.
          const account = yield* ctx.session.account().pipe(Effect.option);
          if (Option.isNone(account)) return;
          const answer = yield* Effect.result(
            ctx.api.request(
              account.value,
              "POST",
              route`/v1/comma/me/bootstrap`,
              workspaceBootstrapSchema,
              {}
            )
          );
          if (account.value.closed) return;
          if (Result.isSuccess(answer)) {
            const result = answer.success;
            if (result.status === "ready") {
              account.value.setMeta("onboardingWorkspace", result.workspace.id);
              this.#setBootstrap({ status: "ready", workspaceId: result.workspace.id });
              return;
            }
            this.#setBootstrap({ status: "preparing" });
            delayS = Math.min(Math.max(result.retry_after_seconds, 1), MAX_RETRY_S);
          } else {
            const error = answer.failure;
            if (error.status !== undefined && TERMINAL.has(error.status)) {
              this.#setBootstrap({ status: "unavailable" });
              return;
            }
            // No answer at all: say so, and keep trying until the network is back.
            if (error.status === undefined)
              this.#setBootstrap({ status: "preparing", unreachable: true });
          }
          yield* Effect.sleep(delayS * 1000);
        }
      })
    );
  }
}

export { CoreError };
