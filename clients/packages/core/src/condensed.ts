// Settings › Condensed Workspace: a Group's shared list of current facts that every Router and Worker Session keeps
// in context. Read for the workspace a page prefers (else the first) when the page shows it; turning it on or off and
// each edit answers the new list, which replaces the shown one. Kept in memory only.
//
// Bounds: one read per page shown; each change is one request.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { route } from "./api.ts";
import { condensedWorkspaceSchema } from "./comma/schemas.ts";
import type { CondensedWorkspace, CondensedWorkspaceValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const path = (group: string) => route`/v1/comma/groups/${group}/condensed-workspace`;

type Operation =
  | { op: "add"; text: string }
  | { op: "replace"; id: string; text: string }
  | { op: "remove"; id: string };

function operations(raw: unknown): Operation[] {
  const list = (raw as { operations?: unknown } | null)?.operations;
  if (!Array.isArray(list) || list.length === 0 || list.length > 100)
    throw CoreError.invalid("operations are required");
  return list.map((o) => {
    const op = o as Record<string, unknown>;
    const text = typeof op.text === "string" ? op.text : undefined;
    const id = typeof op.id === "string" && op.id ? op.id : undefined;
    if (op.op === "add" && text) return { op: "add", text };
    if (op.op === "replace" && id && text) return { op: "replace", id, text };
    if (op.op === "remove" && id) return { op: "remove", id };
    throw CoreError.invalid("an operation is add, replace or remove");
  });
}

export class Condensed {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, CondensedWorkspaceValue>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("condensedWorkspace", {
      start: (topic) => this.#live.run(topic, this.#load(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({
        ok: this.#shown.get(String(topic.prefer ?? "")) ?? {
          group: null,
          state: null,
          error: false,
        },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#shown.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "condensedWorkspace") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#load(topic));
      }
    });
    kernel.calls({
      "condensedWorkspace.setEnabled": {
        doing: true,
        run: (p) => {
          const group = (p as { group?: unknown } | null)?.group;
          const enabled = (p as { enabled?: unknown } | null)?.enabled;
          if (typeof group !== "string" || !group || typeof enabled !== "boolean")
            throw CoreError.invalid("group and enabled are required");
          return this.#write(group, "PUT", `${path(group)}/settings`, { enabled });
        },
      },
      "condensedWorkspace.apply": {
        doing: true,
        run: (p) => {
          const group = (p as { group?: unknown } | null)?.group;
          if (typeof group !== "string" || !group)
            throw CoreError.invalid("group is required");
          return this.#write(group, "POST", `${path(group)}/operations`, {
            operations: operations(p),
          });
        },
      },
    });
  }

  #publish(prefer: string, next: CondensedWorkspaceValue): void {
    this.#shown.set(prefer, next);
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "condensedWorkspace" && String(topic.prefer ?? "") === prefer)
        store.invalidate(topic);
  }

  /** The workspace a page prefers, else the first; then its Group's list. */
  #load(topic: Topic): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const group = (list.find((w) => w.id === prefer) ?? list[0])?.group_id ?? null;
      if (!group) {
        this.#publish(prefer, { group: null, state: null, error: true });
        return;
      }
      const state = yield* ctx.api
        .request(account.value, "GET", path(group), condensedWorkspaceSchema)
        .pipe(Effect.option);
      this.#publish(prefer, {
        group,
        state: Option.getOrNull(state),
        error: Option.isNone(state),
      });
    });
  }

  /** A change; its answer replaces the list on every page showing that Group. */
  #write(
    group: string,
    method: "PUT" | "POST",
    to: string,
    body: unknown
  ): Effect.Effect<null, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, method, to, condensedWorkspaceSchema, body)
      ),
      Effect.tap((state) =>
        Effect.sync(() => {
          for (const [prefer, shown] of this.#shown)
            if (shown.group === group)
              this.#publish(prefer, {
                group,
                state: state as CondensedWorkspace,
                error: false,
              });
        })
      ),
      Effect.as(null)
    );
  }
}
