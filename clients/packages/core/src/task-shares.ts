// A Task's public link (the Share dialog) and Settings › Shared tasks (a Group's active links).
//
// The dialog's link is read when it opens and shows only what the server confirmed: a publish, reset or stop shows its
// answer. A stopped link leaves the Shared tasks list at once; the list reads 50 links a page, the next when asked.
//
// Bounds: one read per dialog opened (and per retry); one list read per page asked, the newest one's answer kept; each
// change is one request.
import {
  CoreError,
  Priority,
  topicKey,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskSharePageSchema, taskShareSchema } from "./comma/schemas.ts";
import type {
  SharedTask,
  TaskShare,
  TaskSharesValue,
  TaskShareValue,
  TaskWorkspace,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Tasks } from "./tasks.ts";
import type { Workspaces } from "./workspaces.ts";

type Shown = {
  workspace: TaskWorkspace | null;
  shares: SharedTask[];
  cursor: string | null;
  loading: boolean;
  error: string | null;
  /** Counts up per read: only the newest read's answer is kept. */
  reads: number;
};

const string = (raw: unknown, name: string): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 256)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

const listKey = (topic: Topic) => String(topic.workspace ?? "");
const linkKey = (group: string, conversation: string) =>
  `${group}\u0000${conversation}`;
const sharePath = (group: string, conversation: string) =>
  `${route`/v1/comma/groups/${group}/conversations/${conversation}`}/share`;

export class TaskShares {
  readonly #ctx: Ctx;
  readonly #tasks: Tasks;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #lists = new Map<string, Shown>();
  /** The link each dialog open now shows (by its topic: each opening is one, `visit`). */
  readonly #links = new Map<string, TaskShareValue>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, tasks: Tasks, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#tasks = tasks;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskShares", {
      start: (topic) => {
        this.#lists.set(listKey(topic), TaskShares.#empty());
        this.#live.run(topic, this.#readList(topic, false));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#lists.delete(listKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#listValue(topic) }),
    });
    kernel.source("taskShare", {
      start: (topic) => {
        this.#links.set(topicKey(topic), { status: "loading", share: null });
        this.#live.run(topic, this.#readLink(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#links.delete(topicKey(topic));
      },
      compute: (topic): Value => ({
        ok: this.#links.get(topicKey(topic)) ?? { status: "loading", share: null },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic === "taskShares") {
          this.#live.stop(topic);
          this.#lists.set(listKey(topic), TaskShares.#empty());
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#readList(topic, false));
        } else if (topic.topic === "taskShare") {
          this.#live.stop(topic);
          this.#show(topic, { status: "loading", share: null });
          this.#live.run(topic, this.#readLink(topic));
        }
      }
    });
    kernel.calls({
      "taskShares.refresh": {
        run: (p) => this.#eachList(p, (topic) => this.#readList(topic, false)),
      },
      "taskShares.more": {
        run: (p) => this.#eachList(p, (topic) => this.#readList(topic, true)),
      },
      "taskShare.refresh": {
        run: (p) => {
          const key = linkKey(string(p, "group"), string(p, "conversation"));
          return Effect.forEach(
            kernel.store
              .liveTopics()
              .filter((t) => t.topic === "taskShare" && this.#linkOf(t) === key),
            (topic) =>
              Effect.suspend(() => {
                this.#show(topic, { status: "loading", share: null });
                return this.#readLink(topic);
              })
          ).pipe(Effect.as(null));
        },
      },
      "taskShare.publish": {
        doing: true,
        run: (p) => this.#change(p, "PUT", ""),
      },
      "taskShare.reset": {
        doing: true,
        run: (p) => this.#change(p, "POST", "/reset"),
      },
      "taskShare.revoke": {
        doing: true,
        run: (p) => {
          const group = string(p, "group");
          const conversation = string(p, "conversation");
          return this.#send(
            "DELETE",
            sharePath(group, conversation),
            z.object({ revoked: z.literal(true) }).strip()
          ).pipe(
            Effect.tap(() =>
              Effect.sync(() => {
                this.#setLink(linkKey(group, conversation), {
                  status: "ready",
                  share: null,
                });
                // Its link is gone from every page.
                for (const [key, shown] of this.#lists) {
                  if (!shown.shares.some((s) => s.id === conversation)) continue;
                  shown.shares = shown.shares.filter((s) => s.id !== conversation);
                  this.#listChanged(key);
                }
              })
            ),
            Effect.as(null)
          );
        },
      },
    });
  }

  static #empty(): Shown {
    return {
      workspace: null,
      shares: [],
      cursor: null,
      loading: true,
      error: null,
      reads: 0,
    };
  }

  #linkOf(topic: Topic): string {
    return linkKey(String(topic.group ?? ""), String(topic.conversation ?? ""));
  }

  #send<S extends z.ZodType>(
    method: "GET" | "PUT" | "POST" | "DELETE",
    path: string,
    schema: S
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) => ctx.api.request(account, method, path, schema))
      );
  }

  /** A publish or reset: the dialog shows the link the server answered. */
  #change(
    p: unknown,
    method: "PUT" | "POST",
    suffix: string
  ): Effect.Effect<TaskShare, CoreError> {
    const group = string(p, "group");
    const conversation = string(p, "conversation");
    return this.#send(
      method,
      `${sharePath(group, conversation)}${suffix}`,
      taskShareSchema
    ).pipe(
      Effect.tap((share) =>
        Effect.sync(() =>
          this.#setLink(linkKey(group, conversation), { status: "ready", share })
        )
      )
    );
  }

  /** What a dialog open now shows. */
  #show(topic: Topic, value: TaskShareValue): void {
    if (!this.#links.has(topicKey(topic))) return;
    this.#links.set(topicKey(topic), value);
    this.#ctx.kernel.store.invalidate(topic);
  }

  /** Every dialog open on the link shows `value`. */
  #setLink(key: string, value: TaskShareValue): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "taskShare" && this.#linkOf(topic) === key)
        this.#show(topic, value);
  }

  #readLink(topic: Topic): Effect.Effect<void> {
    const group = String(topic.group);
    const conversation = String(topic.conversation);
    return this.#send("GET", sharePath(group, conversation), taskShareSchema).pipe(
      Effect.map((share): TaskShare | null => share),
      // No link: the Task is not shared.
      Effect.catchIf(
        (e: CoreError) => e.status === 404,
        () => Effect.succeed(null)
      ),
      Effect.match({
        onSuccess: (share): TaskShareValue => ({ status: "ready", share }),
        onFailure: (): TaskShareValue => ({ status: "failed", share: null }),
      }),
      Effect.tap((value) => Effect.sync(() => this.#show(topic, value))),
      Effect.asVoid
    );
  }

  #listTopics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "taskShares");
  }

  #listChanged(key: string): void {
    for (const topic of this.#listTopics())
      if (listKey(topic) === key) this.#ctx.kernel.store.invalidate(topic);
  }

  #eachList(
    p: unknown,
    work: (topic: Topic) => Effect.Effect<void>
  ): Effect.Effect<null> {
    const workspace = (p as { workspace?: unknown } | null)?.workspace;
    return Effect.forEach(
      this.#listTopics().filter(
        (t) => typeof workspace !== "string" || listKey(t) === workspace
      ),
      work
    ).pipe(Effect.as(null));
  }

  #workspaceOf(account: Account, wanted: string): Effect.Effect<TaskWorkspace | null> {
    return Effect.gen({ self: this }, function* () {
      const known = this.#tasks.workspace(account, wanted);
      if (known) return known;
      yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      return this.#tasks.workspace(account, wanted);
    });
  }

  /** Reads the first page (replacing what is shown), or with `more` the next one. */
  #readList(topic: Topic, more: boolean): Effect.Effect<void> {
    const key = listKey(topic);
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const shown = this.#lists.get(key);
      if (!shown) return;
      const cursor = more ? shown.cursor : null;
      if (more && !cursor) return;
      const read = ++shown.reads;
      shown.loading = true;
      shown.error = null;
      this.#listChanged(key);
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const workspace = yield* this.#workspaceOf(account.value, key);
      if (this.#lists.get(key) !== shown || read !== shown.reads) return;
      if (!workspace) {
        Object.assign(shown, {
          workspace: null,
          shares: [],
          cursor: null,
          loading: false,
        });
        this.#listChanged(key);
        return;
      }
      const query = cursor ? `?${new URLSearchParams({ cursor })}` : "";
      const page = yield* ctx.api
        .request(
          account.value,
          "GET",
          `${route`/v1/comma/groups/${workspace.group_id}/task-shares`}${query}`,
          taskSharePageSchema
        )
        .pipe(Effect.result);
      if (this.#lists.get(key) !== shown || read !== shown.reads) return;
      shown.loading = false;
      if (Result.isFailure(page)) {
        shown.error = page.failure.message;
        this.#listChanged(key);
        return;
      }
      const rows = page.success.data.map(
        (entry): SharedTask => ({
          id: entry.conversation.id,
          title: entry.conversation.title,
          shared_at: entry.shared_at,
          artifact_count: entry.artifact_count,
        })
      );
      const same = shown.workspace?.id === workspace.id;
      shown.workspace = workspace;
      shown.shares = (cursor && same ? [...shown.shares, ...rows] : rows).filter(
        (row, i, all) => all.findIndex((other) => other.id === row.id) === i
      );
      shown.cursor = page.success.has_more ? page.success.next_cursor : null;
      this.#listChanged(key);
    });
  }

  #listValue(topic: Topic): TaskSharesValue {
    const shown = this.#lists.get(listKey(topic)) ?? TaskShares.#empty();
    return {
      workspace: shown.workspace,
      shares: shown.shares,
      hasMore: shown.cursor !== null,
      loading: shown.loading,
      error: shown.error,
    };
  }
}
