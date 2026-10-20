// A Group's Task-board arrangement (the board, Home's rail and the phones' lists): bucket → ordered conversation ids,
// kept on the device (`doc` "taskOrder:<group>") and read again when a surface shows it. Its value is the focused
// list's Tasks of the Group in sections, in the one order of statuses and cards every client shows.
//
// A drop shows at once and is written through to the Group. Writes go one at a time per bucket: while one is under way,
// only the newest drop waits, and it is sent after the one under way settles (an answer cannot overtake a newer drop).
// A read that started before a drop does not undo it. A failed write keeps the arrangement on this device (the cards a
// person placed do not move back) and fails the drop's call, so the UI says it was not saved.
//
// Bounds: one read per showing; per bucket one write in flight and one waiting.
import { visibleTaskStatusBuckets } from "@comma/i18n";
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Deferred, Effect, Option, Result } from "effect";
import type { Watch } from "@comma/core-kernel";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskOrderSchema } from "./comma/schemas.ts";
import type { ProductInboxListResult, TaskOrderValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

type Orders = Record<string, string[]>;

type Write = { ids: string[]; done: Deferred.Deferred<null, CoreError> };
type Lane = { waiting: Write | undefined };

const doc = (group: string) => `taskOrder:${group}`;
/** The list in focus: the Tasks the arrangement puts in order. */
const FOCUSED: Topic = { topic: "tasks", workspace: "" };
const orderPath = (group: string) => route`/v1/comma/groups/${group}/task-order`;

const string = (raw: unknown, name: string, max = 256): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

/**
 * A bucket's Tasks (`ids`, in list order) in board order: those `order` does not name first, keeping list order (where
 * the default, most recently updated first, puts them anyway), then the named ones in `order`'s order.
 */
export function arranged(
  ids: readonly string[],
  order: readonly string[] | undefined
): string[] {
  if (!order?.length) return [...ids];
  const rank = new Map(order.map((id, index) => [id, index]));
  const named = ids
    .filter((id) => rank.has(id))
    .toSorted((a, b) => rank.get(a)! - rank.get(b)!);
  return [...ids.filter((id) => !rank.has(id)), ...named];
}

/** The bucket's stored order with the shown cards in their new order, each in a slot the shown ones held. */
export function placed(
  stored: readonly string[],
  visible: readonly string[]
): string[] {
  const shown = new Set(visible);
  const remaining = [...visible];
  const out = stored.flatMap((id) =>
    shown.has(id) ? (remaining.length ? [remaining.shift()!] : []) : [id]
  );
  out.push(...remaining);
  return out;
}

export class TaskOrder {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #lanes = new Map<string, Lane>();
  /** Counts up per drop of each Group: a read that started before one is not applied. */
  readonly #drops = new Map<string, number>();
  #accountKey: string | null = null;
  /** The list in focus, watched while an arrangement is shown. */
  #watch: Watch | null = null;
  /** The Groups whose arrangement is shown. */
  readonly #shown = new Set<string>();

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskOrder", {
      start: (topic) => {
        this.#shown.add(String(topic.group));
        this.#watch ??= kernel.store.watch(FOCUSED, () =>
          kernel.store.invalidateAll((t) => t.topic === "taskOrder")
        );
        this.#live.run(topic, this.#read(String(topic.group)));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.group));
        if (this.#shown.size > 0) return;
        this.#watch?.drop();
        this.#watch = null;
      },
      compute: (topic): Value => ({ ok: this.#value(String(topic.group)) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#drops.clear();
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(String(topic.group)));
      }
    });
    kernel.calls({
      "taskOrder.set": {
        run: (p) => {
          const group = string(p, "group");
          const bucket = string(p, "bucket", 64);
          const visible = (p as { visible?: unknown }).visible;
          if (
            !Array.isArray(visible) ||
            visible.length > 1_000 ||
            !visible.every((id) => typeof id === "string" && id !== "")
          )
            throw CoreError.invalid("visible is a list of conversation ids");
          return ctx.session
            .account()
            .pipe(
              Effect.flatMap((account) =>
                this.#set(account, group, bucket, visible as string[])
              )
            );
        },
      },
    });
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "taskOrder");
  }

  #changed(group: string): void {
    this.#ctx.kernel.store.invalidateAll(
      (t) => t.topic === "taskOrder" && t.group === group
    );
  }

  #read(group: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const drops = this.#drops.get(group) ?? 0;
      const read = yield* ctx.api
        .request(account.value, "GET", orderPath(group), taskOrderSchema)
        .pipe(Effect.option);
      // Unread, the board shows the projection's order (or what is kept): only a failed save is worth saying.
      if (Option.isNone(read) || account.value.closed) return;
      // A drop since the read began is newer than what it says.
      if ((this.#drops.get(group) ?? 0) !== drops) return;
      account.value.putDoc(doc(group), read.value.orders, ctx.now());
      this.#changed(group);
    });
  }

  #set(
    account: Account,
    group: string,
    bucket: string,
    visible: string[]
  ): Effect.Effect<null, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const orders = account.doc<Orders>(doc(group))?.value ?? {};
      const ids = placed(orders[bucket] ?? [], visible);
      this.#drops.set(group, (this.#drops.get(group) ?? 0) + 1);
      account.putDoc(doc(group), { ...orders, [bucket]: ids }, ctx.now());
      this.#changed(group);
      const write: Write = { ids, done: yield* Deferred.make<null, CoreError>() };
      const key = `${account.dbName}\u0000${group}\u0000${bucket}`;
      const lane = this.#lanes.get(key);
      if (lane) {
        // Replaced before it was sent: the newer drop carries it.
        if (lane.waiting) yield* Deferred.succeed(lane.waiting.done, null);
        lane.waiting = write;
      } else {
        const started: Lane = { waiting: write };
        this.#lanes.set(key, started);
        ctx.runner.fork(this.#drain(account, group, bucket, key, started));
      }
      return yield* Deferred.await(write.done);
    });
  }

  #drain(
    account: Account,
    group: string,
    bucket: string,
    key: string,
    lane: Lane
  ): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      while (lane.waiting) {
        const write = lane.waiting;
        lane.waiting = undefined;
        const sent = yield* ctx.api
          .request(
            account,
            "PUT",
            `${orderPath(group)}/${encodeURIComponent(bucket)}`,
            taskOrderSchema,
            {
              ids: write.ids,
            }
          )
          .pipe(Effect.result);
        yield* Result.isSuccess(sent)
          ? Deferred.succeed(write.done, null)
          : Deferred.fail(write.done, sent.failure);
      }
      if (this.#lanes.get(key) === lane) this.#lanes.delete(key);
    });
  }

  #value(group: string): TaskOrderValue {
    const orders = this.#ctx.session.current()?.doc<Orders>(doc(group))?.value ?? {};
    const list = this.#ctx.kernel.store.get(FOCUSED) as
      | ProductInboxListResult
      | null
      | undefined;
    const byBucket: Record<string, string[]> = {};
    for (const item of list?.items ?? []) {
      if (item.groupId !== group || item.kind !== "agent_task" || !item.statusBucket)
        continue;
      (byBucket[item.statusBucket] ??= []).push(item.conversationId);
    }
    return {
      orders,
      sections: visibleTaskStatusBuckets.map((bucket) => ({
        bucket,
        ids: arranged(byBucket[bucket] ?? [], orders[bucket]),
      })),
    };
  }
}
