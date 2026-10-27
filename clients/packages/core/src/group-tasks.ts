// A Group's agent Tasks and one Task's preview with its Worker, for the read-only Task panel a chat hosts (Telegram,
// WeChat). Its session can be a read-only Group session without the account's workspaces, so this reads the Group
// itself, not the workspace's list (`tasks`). Read when shown and kept only while shown: a new `read` (a retry or a
// refresh) reads again from the start. A failed read shows nothing of the one before.
//
// Bounds: pages of 20 conversations (the agent Tasks among them shown), one next page in flight per list; each request
// given up after 10 s.
import { CoreError, topicKey, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import {
  commaConversationPreviewSchema,
  commaConversationSchema,
  taskLoop,
  type CommaConversation,
  type CommaConversationPreview,
} from "./comma/api-schemas.ts";
import { taskPageSchema } from "./comma/schemas.ts";
import type { GroupTask, GroupTaskValue, GroupTasksValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

export const GROUP_TASKS_PAGE = 20;
const TIMEOUT_MS = 10_000;

type Listed = Extract<GroupTasksValue, { status: "ready" }> & { cursor?: string };

/** A read preview, with its Loop when the Task is a Loop Task. */
function readyPreview(preview: CommaConversationPreview): NonNullable<GroupTaskValue> {
  const loop = taskLoop(preview.loop);
  return { status: "ready", preview, ...(loop ? { loop } : {}) };
}

function groupTask(conversation: CommaConversation): GroupTask {
  return {
    id: conversation.id,
    title: conversation.title,
    status: conversation.status,
    updatedAt: conversation.updated_at ?? 0,
    activityStatus: conversation.activity_status ?? "idle",
  };
}

export class GroupTasks {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** By topic (its `read` included), while shown. */
  readonly #lists = new Map<string, Listed | { status: "failed" }>();
  readonly #previews = new Map<string, NonNullable<GroupTaskValue>>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("groupTasks", {
      start: (topic) => this.#live.run(topic, this.#list(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#lists.delete(topicKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    kernel.source("groupTask", {
      start: (topic) => this.#live.run(topic, this.#preview(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#previews.delete(topicKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#previews.get(topicKey(topic)) ?? null }),
    });
    kernel.calls({
      "groupTasks.more": {
        run: (p) =>
          Effect.sync(() => {
            const params = p as { group?: unknown; read?: unknown } | null;
            if (typeof params?.group !== "string")
              throw CoreError.invalid("group is required");
            const read = typeof params.read === "string" ? params.read : "";
            const topic = kernel.store
              .liveTopics()
              .find(
                (t) =>
                  t.topic === "groupTasks" &&
                  t.group === params.group &&
                  String(t.read ?? "") === read
              );
            if (topic) this.#more(topic);
            return null;
          }),
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Another account (or none): nothing of the one before stays shown.
      this.#lists.clear();
      this.#previews.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "groupTasks" && topic.topic !== "groupTask") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(
          topic,
          topic.topic === "groupTasks" ? this.#list(topic) : this.#preview(topic)
        );
      }
    });
  }

  #value(topic: Topic): GroupTasksValue {
    const listed = this.#lists.get(topicKey(topic));
    if (!listed || listed.status === "failed") return listed ?? null;
    return { status: "ready", tasks: listed.tasks, more: listed.more };
  }

  #page(group: string, cursor: string | undefined) {
    const query = `${cursor ? `cursor=${encodeURIComponent(cursor)}&` : ""}limit=${GROUP_TASKS_PAGE}`;
    return `${route`/v1/comma/groups/${group}/conversations`}?${query}`;
  }

  /** The first page. */
  #list(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = topicKey(topic);
    const group = String(topic.group ?? "");
    return Effect.gen({ self: this }, function* () {
      if (!group) {
        this.#lists.set(key, { status: "failed" });
        ctx.kernel.store.invalidate(topic);
        return;
      }
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const answer = yield* ctx.api
        .request(
          account.value,
          "GET",
          this.#page(group, undefined),
          taskPageSchema(commaConversationSchema),
          undefined,
          TIMEOUT_MS
        )
        .pipe(Effect.result);
      if (Result.isSuccess(answer)) {
        const page = answer.success;
        const cursor = page.next_cursor ?? undefined;
        this.#lists.set(key, {
          status: "ready",
          tasks: page.data.filter((c) => c.kind === "agent_task").map(groupTask),
          more: page.has_more === true && cursor ? "idle" : "none",
          ...(cursor ? { cursor } : {}),
        });
      } else {
        this.#lists.set(key, { status: "failed" });
      }
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** The next page, after what the list shows; one at a time. A failure keeps the list and says so. */
  #more(topic: Topic): void {
    const ctx = this.#ctx;
    const key = topicKey(topic);
    const listed = this.#lists.get(key);
    if (
      listed?.status !== "ready" ||
      !listed.cursor ||
      listed.more === "none" ||
      listed.more === "loading"
    )
      return;
    const { cursor } = listed;
    const loading: Listed = { ...listed, more: "loading" };
    this.#lists.set(key, loading);
    ctx.kernel.store.invalidate(topic);
    this.#live.run(
      topic,
      Effect.gen({ self: this }, function* () {
        const answer = yield* ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "GET",
              this.#page(String(topic.group), cursor),
              taskPageSchema(commaConversationSchema),
              undefined,
              TIMEOUT_MS
            )
          ),
          Effect.result
        );
        // The list was read again (or let go) meanwhile: this page is not its next one.
        if (this.#lists.get(key) !== loading) return;
        if (Result.isSuccess(answer)) {
          const page = answer.success;
          const next = page.next_cursor ?? undefined;
          const { cursor: _, ...rest } = loading;
          this.#lists.set(key, {
            ...rest,
            tasks: [
              ...loading.tasks,
              ...page.data.filter((c) => c.kind === "agent_task").map(groupTask),
            ],
            more: page.has_more === true && next ? "idle" : "none",
            ...(next ? { cursor: next } : {}),
          });
        } else {
          this.#lists.set(key, { ...loading, more: "failed" });
        }
        ctx.kernel.store.invalidate(topic);
      })
    );
  }

  /** The Task's preview with its Worker. */
  #preview(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = topicKey(topic);
    const path = `${route`/v1/comma/groups/${String(topic.group)}/conversations/${String(topic.conversation)}`}/preview?include_worker=true`;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const answer = yield* ctx.api
        .request(
          account.value,
          "GET",
          path,
          commaConversationPreviewSchema,
          undefined,
          TIMEOUT_MS
        )
        .pipe(Effect.result);
      this.#previews.set(
        key,
        Result.isSuccess(answer) ? readyPreview(answer.success) : { status: "failed" }
      );
      ctx.kernel.store.invalidate(topic);
    });
  }
}
