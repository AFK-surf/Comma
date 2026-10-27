// The bound Worker of the Tasks a chat's reply slot follows (its activity focus), from each Task's participant feed.
// A feed is a finite long-poll (`wait` 30 s): a normal end reads again, but no sooner than a second after the last
// read began; a failure waits 1, 2, 4, 8, then 15 s, and a snapshot or a normal end resets that wait. The last
// snapshot stays through reconnects. A Task no shown topic names closes its feed and forgets its Worker.
//
// Bounds: one feed per followed Task, shared by every topic that names it; each topic names at most 2 (the UI's
// `MAX_FOCUS_TASK_FEEDS`, kept here too); a feed reconnects at most once a second.
import { type Scoped, type Topic, type Value } from "@comma/core-kernel";
import { Duration, Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { taskRun } from "./chat/model/conversationChannel.ts";
import {
  commaTaskParticipantStatusesSchema,
  type CommaTaskRun,
} from "./comma/api-schemas.ts";
import type { TaskWorker, TaskWorkersValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { HostedTasks } from "./hosted-tasks.ts";
import { readEvents } from "./sse.ts";

export const TASK_FEED_WAIT_MS = 30_000;
export const TASK_FEED_MIN_INTERVAL_MS = 1_000;
const TASK_FEED_MAX_BACKOFF_MS = 15_000;
const MAX_FEEDS_PER_TOPIC = 2;

const keyFor = (group: string, id: string) => `${group}\u0000${id}`;

/** The Tasks a topic follows, each once, at most 2. */
function idsOf(topic: Topic): string[] {
  const raw = typeof topic.ids === "string" ? topic.ids : "";
  return [...new Set(raw.split(",").filter((id) => id !== ""))].slice(
    0,
    MAX_FEEDS_PER_TOPIC
  );
}

type Feed = { count: number; scope: Scoped };

export class TaskWorkers {
  readonly #ctx: Ctx;
  readonly #feeds = new Map<string, Feed>();
  /** Each followed Task's Worker as its last snapshot said (null: none bound yet); absent before one. */
  readonly #workers = new Map<string, TaskWorker | null>();
  #accountKey: string | null = null;
  /** Tasks Comma's server does not keep: they have no Worker of Comma's, and none is followed for them. */
  hosted: HostedTasks | undefined;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("taskWorkers", {
      start: (topic) => {
        for (const id of idsOf(topic))
          if (!this.hosted?.owns(id)) this.#retain(String(topic.group), id);
      },
      stop: (topic) => {
        for (const id of idsOf(topic))
          if (!this.hosted?.owns(id)) this.#release(String(topic.group), id);
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
      evictAfterMs: 0,
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account was told is shown to another; the feeds read again as the new one.
      this.#workers.clear();
      kernel.store.invalidateAll((t) => t.topic === "taskWorkers");
    });
  }

  #value(topic: Topic): TaskWorkersValue {
    const group = String(topic.group);
    const value: TaskWorkersValue = {};
    for (const id of idsOf(topic)) {
      const worker = this.hosted?.owns(id)
        ? null
        : this.#workers.get(keyFor(group, id));
      if (worker !== undefined) value[id] = worker;
    }
    return value;
  }

  #retain(group: string, id: string): void {
    const key = keyFor(group, id);
    const feed = this.#feeds.get(key);
    if (feed) {
      feed.count += 1;
      return;
    }
    const scope = this.#ctx.runner.child();
    this.#feeds.set(key, { count: 1, scope });
    this.#ctx.runner.fork(this.#follow(group, id), scope);
  }

  #release(group: string, id: string): void {
    const key = keyFor(group, id);
    const feed = this.#feeds.get(key);
    if (!feed) return;
    feed.count -= 1;
    if (feed.count > 0) return;
    this.#feeds.delete(key);
    this.#workers.delete(key);
    this.#ctx.runner.close(feed.scope);
  }

  #set(group: string, id: string, worker: TaskWorker | null): void {
    this.#workers.set(keyFor(group, id), worker);
    this.#ctx.kernel.store.invalidateAll(
      (t) => t.topic === "taskWorkers" && String(t.group) === group
    );
  }

  /** The feed of Task `id`, for as long as its scope is open. */
  #follow(group: string, id: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    const query = new URLSearchParams({
      wait: String(TASK_FEED_WAIT_MS),
      conversation_id: id,
    });
    const path = `${route`/v1/comma/groups/${group}/conversations/events`}?${query}`;
    return Effect.gen({ self: this }, function* () {
      let backoff = 0;
      for (;;) {
        const account = yield* ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account)) return;
        const startedAt = ctx.now();
        const ended = yield* Effect.scoped(
          Effect.gen({ self: this }, function* () {
            const body = yield* ctx.api.stream(account.value, path);
            yield* readEvents(body, (value, event) =>
              Effect.sync(() => {
                if (event !== "task_participant_statuses") return;
                const parsed = commaTaskParticipantStatusesSchema.safeParse(value);
                if (
                  !parsed.success ||
                  parsed.data.group_id !== group ||
                  parsed.data.conversation_id !== id
                )
                  return;
                backoff = 0;
                // A Task with no bound Worker yet is a known answer: null.
                this.#set(group, id, boundWorker(parsed.data));
              })
            );
          })
        ).pipe(Effect.result);
        if (Result.isSuccess(ended)) {
          backoff = 0;
          const wait = TASK_FEED_MIN_INTERVAL_MS - (ctx.now() - startedAt);
          if (wait > 0) yield* Effect.sleep(Duration.millis(wait));
        } else {
          backoff = Math.min(TASK_FEED_MAX_BACKOFF_MS, backoff ? backoff * 2 : 1_000);
          yield* Effect.sleep(Duration.millis(backoff));
        }
      }
    });
  }
}

function boundWorker(event: {
  bound_worker?:
    | { participant_id: string; actor_id?: string | undefined; name: string }
    | null
    | undefined;
  run?: CommaTaskRun | undefined;
  participants: readonly { participant_id: string; state: string }[];
}): TaskWorker | null {
  const bound = event.bound_worker;
  if (!bound) return null;
  const participant = event.participants.find(
    (candidate) => candidate.participant_id === bound.participant_id
  );
  const vendor = taskRun(event.run)?.vendor;
  return {
    ...(vendor ? { vendor } : {}),
    avatarId: bound.actor_id ?? bound.participant_id,
    name: bound.name,
    participantId: bound.participant_id,
    // The feed omits a waiting Participant: listed and active means working.
    active: participant?.state === "active",
    failed: participant?.state === "error",
  };
}
