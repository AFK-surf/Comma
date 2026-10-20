// Settings › Tailscale: a workspace's node in its own Tailscale network. The login link a waiting node has is kept in
// memory only and never written to the device: whoever opens it adds the node to their tailnet.
//
// Bounds, per shown page (`prefer`): one request at a time (a read or what a person asked); the status is read every
// 3 s while the node waits for a tailnet admin (the server drops the link after 30 minutes), and the peers once each
// time a read finds the node running. A failed read stops the reads until the person refreshes.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import type { z } from "zod";
import { route } from "./api.ts";
import { tailnetPeersSchema, tailnetStatusSchema } from "./comma/schemas.ts";
import type { TailnetSettings, TailnetStatus, TailnetValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const CHECK_EVERY_MS = 3_000;
const WAITING = new Set<TailnetStatus["state"]>([
  "starting",
  "needs_login",
  "needs_approval",
]);
const TAG = /^tag:[A-Za-z][A-Za-z0-9-]{0,62}$/;

const tailnetPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/tailnet`;
const peersPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/tailnet/peers`;

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  settings(raw: unknown): TailnetSettings {
    const p = (raw ?? {}) as Record<string, unknown>;
    const tags = p.tags;
    if (
      !Array.isArray(tags) ||
      tags.length > 8 ||
      !tags.every((tag) => typeof tag === "string" && TAG.test(tag))
    )
      throw CoreError.invalid("tags are at most 8 tags like tag:name");
    if (typeof p.accept_routes !== "boolean")
      throw CoreError.invalid("accept_routes is true or false");
    const expected = p.expected_tailnet;
    if (expected !== null && expected !== undefined && typeof expected !== "string")
      throw CoreError.invalid("expected_tailnet is a name");
    return {
      tags: tags as string[],
      accept_routes: p.accept_routes,
      expected_tailnet:
        typeof expected === "string" && expected.trim() ? expected.trim() : null,
    };
  },
};

const empty = (): TailnetValue => ({
  workspace: null,
  status: null,
  peers: null,
  error: false,
  busy: false,
});

const busy = () => new CoreError("busy", "Another change is under way.");

export class Tailnet {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  /** What each shown page (`prefer`) has. */
  readonly #shown = new Map<string, TailnetValue>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("tailnet", {
      start: (topic) => {
        this.#shown.set(String(topic.prefer ?? ""), empty());
        this.#live.run(topic, this.#keep(topic, true));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({
        ok: this.#shown.get(String(topic.prefer ?? "")) ?? empty(),
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): nothing of the one before is shown or read.
      this.#accountKey = key;
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        this.#shown.set(String(topic.prefer ?? ""), empty());
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic, true));
      }
    });

    kernel.calls({
      "tailnet.refresh": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#action(workspace, (topic) => this.#load(topic)).pipe(
            Effect.as(null)
          );
        },
      },
      "tailnet.connect": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const settings = params.settings(p);
          return this.#action(workspace, () =>
            this.#send(
              "PUT",
              tailnetPath(workspace),
              tailnetStatusSchema,
              settings
            ).pipe(
              Effect.tap((status) =>
                Effect.sync(() => this.#set(workspace, { status }))
              )
            )
          );
        },
      },
      "tailnet.disconnect": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#action(workspace, () =>
            this.#send("DELETE", tailnetPath(workspace), tailnetStatusSchema).pipe(
              Effect.tap((status) =>
                Effect.sync(() => this.#set(workspace, { status, peers: null }))
              )
            )
          ).pipe(Effect.as(null));
        },
      },
    });
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "tailnet");
  }

  #publish(prefer: string, next: TailnetValue): void {
    this.#shown.set(prefer, next);
    for (const topic of this.#topics())
      if (String(topic.prefer ?? "") === prefer)
        this.#ctx.kernel.store.invalidate(topic);
  }

  /** Every shown page of `workspace` takes the change. */
  #set(workspace: string, next: Partial<Pick<TailnetValue, "status" | "peers">>): void {
    for (const [prefer, shown] of this.#shown)
      if (shown.workspace === workspace) this.#publish(prefer, { ...shown, ...next });
  }

  /** The workspace a page prefers (the one it is in), else the first; then its status and, when running, peers. */
  #load(topic: Topic): Effect.Effect<void, CoreError> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      if (!this.#workspaces.list(account.value)?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
      const was = this.#shown.get(prefer) ?? empty();
      if (!workspace) {
        this.#publish(prefer, { ...was, workspace: null });
        return;
      }
      // The page knows its workspace even when the read fails, so a refresh finds it.
      if (was.workspace !== workspace) this.#publish(prefer, { ...was, workspace });
      const status = yield* this.#get(tailnetPath(workspace), tailnetStatusSchema);
      const peers =
        status.state === "running"
          ? (yield* this.#get(peersPath(workspace), tailnetPeersSchema)).peers
          : null;
      this.#publish(prefer, {
        ...(this.#shown.get(prefer) ?? was),
        workspace,
        status,
        peers,
        error: false,
      });
    });
  }

  /** Reads first (when shown), then the status every 3 s while the node waits. */
  #keep(topic: Topic, read: boolean): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      if (read) {
        const ok = yield* this.#load(topic).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) return this.#fail(prefer);
      }
      for (;;) {
        const s = this.#shown.get(prefer);
        if (!s || s.busy || s.error || !s.status || !WAITING.has(s.status.state))
          return;
        yield* Effect.sleep(CHECK_EVERY_MS);
        const ok = yield* this.#load(topic).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) return this.#fail(prefer);
      }
    });
  }

  #fail(prefer: string): void {
    const s = this.#shown.get(prefer);
    if (s) this.#publish(prefer, { ...s, error: true });
  }

  /** One change at a time per workspace. A failed read shows until a refresh; a failed change is the caller's to say. */
  #action<A>(
    workspace: string,
    work: (topic: Topic) => Effect.Effect<A, CoreError>
  ): Effect.Effect<A, CoreError> {
    return Effect.suspend(() => {
      const topics = this.#topics().filter(
        (t) => this.#shown.get(String(t.prefer ?? ""))?.workspace === workspace
      );
      const first = topics[0];
      if (!first) return Effect.fail(CoreError.invalid("Tailscale is not shown"));
      if (topics.some((t) => this.#shown.get(String(t.prefer ?? ""))?.busy))
        return Effect.fail(busy());
      this.#mark(topics, { busy: true });
      return work(first).pipe(
        Effect.tap(() => Effect.sync(() => this.#mark(topics, { error: false }))),
        Effect.ensuring(
          Effect.sync(() => {
            this.#mark(topics, { busy: false });
            for (const topic of topics) {
              if (!this.#live.live(topic)) continue;
              this.#live.stop(topic);
              this.#live.run(topic, this.#keep(topic, false));
            }
          })
        )
      );
    });
  }

  #mark(topics: Topic[], next: Partial<Pick<TailnetValue, "busy" | "error">>): void {
    for (const topic of topics) {
      const prefer = String(topic.prefer ?? "");
      const s = this.#shown.get(prefer);
      if (s) this.#publish(prefer, { ...s, ...next });
    }
  }

  #get<S extends z.ZodType>(path: string, schema: S) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(Effect.flatMap((account) => ctx.api.request(account, "GET", path, schema)));
  }

  #send<S extends z.ZodType>(
    method: "PUT" | "DELETE",
    path: string,
    schema: S,
    body?: unknown
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  }
}
