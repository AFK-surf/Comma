// A member's changes to a Task from a list (archiving and unarchiving, a new title, accepting its review, stopping it,
// pinning it), Settings › Archived tasks, and the Tasks pinned in a Group (`taskPins`).
//
// A person's archive leaves every list at once (a `tasks` stage) and only the server's answer decides whether it stays
// gone: refused, the Task comes back. An answer is a fact (the summary cache keeps it); the list in focus reads that
// Task again to reconcile. A conflict (409: the Task changed since the version the person saw) makes the cached facts
// stale and reads the Task again. One change at a time per Task.
//
// The archived list reads 50 Tasks a page (the server's `archive=only` list), the next page when asked; a Task
// unarchived here leaves it. Another change is one request whose answer is the Task's fact, which the list in focus
// reads again. The pins are read while a surface shows them, and again after a pin changes.
//
// Bounds: one archive request per Task in flight; a list read per page asked, the newest one's answer kept; each other
// change is one request, then one read of the Task; one pins read per change or surface shown (at most 100 pins).
import { taskStatusBucket } from "@comma/i18n";
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskPageSchema, taskSummarySchema } from "./comma/schemas.ts";
import type {
  ArchivedTasksValue,
  TaskPinsValue,
  TaskSummary,
  TaskWorkspace,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { TaskSummaries } from "./task-summaries.ts";
import type { Tasks } from "./tasks.ts";
import type { Workspaces } from "./workspaces.ts";

const PAGE = 50;
const pinsSchema = z.object({
  data: z
    .array(
      z
        .object({
          conversation: z.object({ id: z.string(), group_id: z.string() }).strip(),
        })
        .strip()
    )
    .max(100),
});

type Shown = {
  workspace: TaskWorkspace | null;
  tasks: TaskSummary[];
  cursor: string | null;
  loading: boolean;
  error: string | null;
  /** Counts up per read: only the newest read's answer is kept. */
  reads: number;
};

const string = (raw: unknown, name: string, max = 256): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

const keyOf = (topic: Topic) => String(topic.workspace ?? "");

export class TasksArchive {
  readonly #ctx: Ctx;
  readonly #tasks: Tasks;
  readonly #workspaces: Workspaces;
  readonly #summaries: TaskSummaries;
  readonly #live: Live;
  readonly #shown = new Map<string, Shown>();
  /** Each shown Group's pins, by group. */
  readonly #pins = new Map<string, TaskPinsValue>();
  /** The Tasks with an archive or unarchive in flight. */
  readonly #changing = new Set<string>();
  #accountKey: string | null = null;

  constructor(
    ctx: Ctx,
    tasks: Tasks,
    workspaces: Workspaces,
    summaries: TaskSummaries
  ) {
    this.#ctx = ctx;
    this.#tasks = tasks;
    this.#workspaces = workspaces;
    this.#summaries = summaries;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("archivedTasks", {
      start: (topic) => {
        this.#shown.set(keyOf(topic), TasksArchive.#empty());
        this.#live.run(topic, this.#read(topic, false));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(keyOf(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    kernel.source("taskPins", {
      start: (topic) => {
        this.#pins.set(String(topic.group), { status: "loading", ids: [] });
        this.#live.run(topic, this.#readPins(String(topic.group)));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#pins.delete(String(topic.group));
      },
      compute: (topic): Value => ({
        ok: this.#pins.get(String(topic.group)) ?? { status: "loading", ids: [] },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#changing.clear();
      for (const group of this.#pins.keys()) {
        this.#pins.set(group, { status: "loading", ids: [] });
        this.#pinsChanged(group);
        ctx.runner.fork(this.#readPins(group));
      }
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        this.#shown.set(keyOf(topic), TasksArchive.#empty());
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic, false));
      }
    });
    kernel.calls({
      "tasks.archive": {
        doing: true,
        run: (p) => {
          const group = string(p, "group");
          const conversation = string(p, "conversation");
          const raw = p as { action?: unknown; version?: unknown };
          if (raw.action !== "archive" && raw.action !== "unarchive")
            throw CoreError.invalid("action is archive or unarchive");
          if (typeof raw.version !== "number" || !Number.isFinite(raw.version))
            throw CoreError.invalid("version is required");
          return this.#change(group, conversation, raw.action, raw.version);
        },
      },
      "tasks.rename": {
        doing: true,
        run: (p) => {
          const title = string(p, "title", 400).trim();
          if (!title || title.length > 200)
            throw CoreError.invalid("title is at most 200 characters");
          return this.#task(p, "PATCH", "", { title });
        },
      },
      "tasks.accept": {
        doing: true,
        run: (p) => {
          const version = (p as { reviewVersion?: unknown } | null)?.reviewVersion;
          if (typeof version !== "number" || !Number.isInteger(version) || version <= 0)
            throw CoreError.invalid("reviewVersion is required");
          return this.#task(p, "POST", "/accept", { review_version: version });
        },
      },
      "tasks.cancel": {
        doing: true,
        run: (p) => this.#task(p, "POST", "/cancel", {}),
      },
      "tasks.pin": {
        doing: true,
        run: (p) => {
          const group = string(p, "group");
          const conversation = string(p, "conversation");
          const pinned = (p as { pinned?: unknown } | null)?.pinned === true;
          const shown = this.#pins.get(group);
          // Shown at once; the pins read again after the server answered say what holds.
          if (shown) {
            const ids = shown.ids.filter((id) => id !== conversation);
            this.#pins.set(group, {
              ...shown,
              ids: pinned ? [...ids, conversation] : ids,
            });
            this.#pinsChanged(group);
          }
          const path = `${route`/v1/comma/groups/${group}/conversations/${conversation}`}/pin`;
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                pinned ? "PUT" : "DELETE",
                path,
                z.unknown(),
                pinned ? {} : undefined
              )
            ),
            Effect.ensuring(
              this.#pins.has(group) ? this.#readPins(group) : Effect.void
            ),
            Effect.as(null)
          );
        },
      },
      "archivedTasks.refresh": {
        run: (p) => this.#each(p, (topic) => this.#read(topic, false)),
      },
      "archivedTasks.more": {
        run: (p) => this.#each(p, (topic) => this.#read(topic, true)),
      },
    });
  }

  static #empty(): Shown {
    return {
      workspace: null,
      tasks: [],
      cursor: null,
      loading: true,
      error: null,
      reads: 0,
    };
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((t) => t.topic === "archivedTasks");
  }

  #changed(key: string): void {
    for (const topic of this.#topics())
      if (keyOf(topic) === key) this.#ctx.kernel.store.invalidate(topic);
  }

  /** Runs `work` for the shown lists of `workspace` (all of them when it is not given). */
  #each(p: unknown, work: (topic: Topic) => Effect.Effect<void>): Effect.Effect<null> {
    const workspace = (p as { workspace?: unknown } | null)?.workspace;
    const topics = this.#topics().filter(
      (t) => typeof workspace !== "string" || keyOf(t) === workspace
    );
    return Effect.forEach(topics, work).pipe(Effect.as(null));
  }

  #change(
    group: string,
    conversation: string,
    action: "archive" | "unarchive",
    version: number
  ): Effect.Effect<boolean, CoreError> {
    const ctx = this.#ctx;
    const key = `${group}\u0000${conversation}`;
    return Effect.suspend(() => {
      if (this.#changing.has(key)) return Effect.succeed(false);
      this.#changing.add(key);
      // The person decided: every list stops showing the Task now, and the answer only decides whether it stays gone.
      const stage =
        action === "archive"
          ? this.#tasks.stage({
              groupId: group,
              conversationId: conversation,
              status: "archived",
              version,
            })
          : undefined;
      return ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "POST",
            `${route`/v1/comma/groups/${group}/conversations/${conversation}`}/${action}`,
            taskSummarySchema,
            { expected_updated_at: version }
          )
        ),
        Effect.tap((committed) =>
          Effect.sync(() => {
            if (stage !== undefined) this.#tasks.settle(stage, true);
            this.#summaries.invalidate();
            this.#summaries.record(committed);
            if (action === "unarchive") this.#drop(conversation);
            this.#reconcile(conversation);
          })
        ),
        Effect.tapError((error) =>
          Effect.sync(() => {
            if (stage !== undefined) this.#tasks.settle(stage, false);
            if (error.status === 409) {
              this.#summaries.invalidate();
              this.#reconcile(conversation);
            }
          })
        ),
        Effect.ensuring(Effect.sync(() => this.#changing.delete(key))),
        Effect.as(true)
      );
    });
  }

  /** A change of one Task (`method` at its path and `tail`): its answer is the Task's fact, which the list reads again. */
  #task(
    p: unknown,
    method: "PATCH" | "POST",
    tail: string,
    body: unknown
  ): Effect.Effect<null, CoreError> {
    const group = string(p, "group");
    const conversation = string(p, "conversation");
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          method,
          `${route`/v1/comma/groups/${group}/conversations/${conversation}`}${tail}`,
          taskSummarySchema,
          body
        )
      ),
      Effect.tap((committed) =>
        Effect.sync(() => {
          this.#summaries.invalidate();
          this.#summaries.record(committed);
          this.#reconcile(conversation);
        })
      ),
      Effect.as(null)
    );
  }

  #pinsChanged(group: string): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "taskPins" && String(topic.group) === group)
        this.#ctx.kernel.store.invalidate(topic);
  }

  /** Reads a Group's pins; a failed read keeps the pins shown and says so. */
  #readPins(group: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          "GET",
          route`/v1/comma/groups/${group}/conversation-pins`,
          pinsSchema
        )
      ),
      Effect.match({
        onSuccess: (answer) => {
          if (!this.#pins.has(group)) return;
          this.#pins.set(group, {
            status: "ready",
            ids: answer.data
              .filter((pin) => pin.conversation.group_id === group)
              .map((pin) => pin.conversation.id),
          });
          this.#pinsChanged(group);
        },
        onFailure: () => {
          const shown = this.#pins.get(group);
          if (!shown) return;
          this.#pins.set(group, { ...shown, status: "error" });
          this.#pinsChanged(group);
        },
      })
    );
  }

  /** The list in focus reads the Task again: from here on it carries the server's fact. */
  #reconcile(conversation: string): void {
    this.#ctx.runner.fork(this.#tasks.reread("", [conversation]).pipe(Effect.ignore));
  }

  /** An unarchived Task leaves every archived list. */
  #drop(conversation: string): void {
    for (const [key, shown] of this.#shown) {
      if (!shown.tasks.some((task) => task.id === conversation)) continue;
      shown.tasks = shown.tasks.filter((task) => task.id !== conversation);
      this.#changed(key);
    }
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
  #read(topic: Topic, more: boolean): Effect.Effect<void> {
    const key = keyOf(topic);
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const shown = this.#shown.get(key);
      if (!shown) return;
      const cursor = more ? shown.cursor : null;
      if (more && (shown.loading || !cursor)) return;
      const read = ++shown.reads;
      shown.loading = true;
      shown.error = null;
      this.#changed(key);
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const workspace = yield* this.#workspaceOf(account.value, key);
      if (this.#shown.get(key) !== shown || read !== shown.reads) return;
      if (!workspace) {
        Object.assign(shown, {
          workspace: null,
          tasks: [],
          cursor: null,
          loading: false,
        });
        this.#changed(key);
        return;
      }
      const query = new URLSearchParams({ archive: "only", limit: String(PAGE) });
      if (cursor) query.set("cursor", cursor);
      const page = yield* ctx.api
        .request(
          account.value,
          "GET",
          `${route`/v1/comma/groups/${workspace.group_id}/conversations`}?${query}`,
          taskPageSchema(taskSummarySchema)
        )
        .pipe(Effect.result);
      if (this.#shown.get(key) !== shown || read !== shown.reads) return;
      shown.loading = false;
      if (Result.isFailure(page)) {
        shown.error = page.failure.message;
        this.#changed(key);
        return;
      }
      const data = page.success.data.filter(
        (task) => task.group_id === workspace.group_id
      );
      const same = shown.workspace?.id === workspace.id;
      shown.workspace = workspace;
      shown.tasks = (cursor && same ? [...shown.tasks, ...data] : data).filter(
        (task, i, all) => all.findIndex((other) => other.id === task.id) === i
      );
      shown.cursor =
        page.success.has_more === true ? (page.success.next_cursor ?? null) : null;
      this.#changed(key);
    });
  }

  #value(topic: Topic): ArchivedTasksValue {
    const shown = this.#shown.get(keyOf(topic)) ?? TasksArchive.#empty();
    return {
      workspace: shown.workspace,
      tasks: shown.tasks.map((task) => ({
        ...task,
        archived_from_bucket: taskStatusBucket(
          task.archived_from_status ?? task.status
        ),
      })),
      hasMore: shown.cursor !== null,
      loading: shown.loading,
      error: shown.error,
    };
  }
}
