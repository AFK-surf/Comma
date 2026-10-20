// Settings › Inbound API: the keys that let an external service post to a workspace's Router. Read while the page shows
// them and after each change. A new key's plaintext is answered to the UI that created it and nowhere else: it is not
// in the topic, and nothing of it is written to the device.
//
// Bounds: one read in flight per page shown (`prefer`); each change is one request, then one read.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { routerKeyCreatedSchema, routerKeySchema } from "./comma/schemas.ts";
import type { RouterKey, RouterKeyCreated, RouterKeysValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const keysPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/router-api-keys`;
const keyPath = (workspace: string, key: string) =>
  route`/v1/comma/workspaces/${workspace}/router-api-keys/${key}`;

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  name(raw: unknown): string {
    const v = (raw as Record<string, unknown> | null)?.name;
    if (typeof v !== "string" || !v.trim() || v.length > 128)
      throw CoreError.invalid("name is required");
    return v.trim();
  },
};

type Shown = { workspace: string | null; keys: RouterKey[] | null; error: boolean };

export class RouterKeys {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  /** What each shown page (`prefer`) has. */
  readonly #shown = new Map<string, Shown>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("routerKeys", {
      start: (topic) => this.#live.run(topic, this.#load(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#shown.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "routerKeys") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#load(topic));
      }
    });

    kernel.calls({
      "routerKeys.refresh": {
        run: () =>
          Effect.forEach(this.#topics(), (topic) => this.#load(topic)).pipe(
            Effect.as(null)
          ),
      },
      "routerKeys.create": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const name = params.name(p);
          return this.#request(
            workspace,
            "POST",
            keysPath(workspace),
            routerKeyCreatedSchema,
            {
              name,
            }
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.map((created): RouterKeyCreated => created)
          );
        },
      },
      "routerKeys.rename": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const key = params.string(p, "key");
          const name = params.name(p);
          return this.#request(
            workspace,
            "PATCH",
            keyPath(workspace, key),
            routerKeySchema,
            {
              name,
            }
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.as(null)
          );
        },
      },
      "routerKeys.setStatus": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const key = params.string(p, "key");
          const status = (p as { status?: unknown } | null)?.status;
          if (status !== "active" && status !== "disabled")
            throw CoreError.invalid("status is active or disabled");
          return this.#request(
            workspace,
            "PATCH",
            keyPath(workspace, key),
            routerKeySchema,
            {
              status,
            }
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.as(null)
          );
        },
      },
      "routerKeys.delete": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const key = params.string(p, "key");
          return this.#request(
            workspace,
            "DELETE",
            keyPath(workspace, key),
            z.object({ deleted: z.boolean() })
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.as(null)
          );
        },
      },
    });
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "routerKeys");
  }

  #request<S extends z.ZodType>(
    _workspace: string,
    method: "POST" | "PATCH" | "DELETE",
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

  /** After a change: every shown page reads again; a failed read shows on the page. */
  #reread(): Effect.Effect<void> {
    return Effect.forEach(this.#topics(), (topic) => this.#load(topic)).pipe(
      Effect.asVoid
    );
  }

  /** The workspace a page prefers (the one it is in), else the first; then its keys. */
  #load(topic: Topic): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const known = this.#workspaces.list(account.value);
      if (!known?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
      const keys = workspace
        ? yield* ctx.api
            .request(
              account.value,
              "GET",
              keysPath(workspace),
              z.array(routerKeySchema)
            )
            .pipe(Effect.option)
        : Option.none();
      const was = this.#shown.get(prefer);
      this.#shown.set(prefer, {
        workspace,
        keys: Option.isSome(keys) ? keys.value : (was?.keys ?? null),
        error: Option.isNone(keys),
      });
      ctx.kernel.store.invalidate(topic);
    });
  }

  #value(topic: Topic): RouterKeysValue {
    const shown = this.#shown.get(String(topic.prefer ?? ""));
    return shown ?? { workspace: null, keys: null, error: false };
  }
}
