// The Tasks surfaces refer to (a chat's Task chips and dock, the briefing's cards, a Task's own header): their facts from
// the list in focus when it has them with a version, else from one bounded summary cache per account.
//
// Only the server's answers put facts in the cache; the list's reads only make them stale. Every read of the list in
// focus (each one, a read that repeats the list included) makes every cached fact stale, and the Tasks shown are read
// again: a Task outside the list's loaded page may have been archived meanwhile. A stale, pending or failed fact is
// shown without its archive permission. A fact never goes back to an older version, so a known archive survives failed
// reads and stale marks.
//
// Bounds: at most 1,000 Tasks per account, none evicted (a Task beyond them shows what its reference says); one
// summary request at a time, at most 50 Tasks of one Group each.
import { taskStatusBucket, taskStatusFailed } from "@comma/i18n";
import { type Topic, type Value, type Watch } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { route } from "./api.ts";
import { taskPageSchema, taskSummarySchema } from "./comma/schemas.ts";
import type {
  ProductInboxItem,
  ProductInboxListResult,
  TaskSummariesValue,
  TaskSummary,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { HostedTasks } from "./hosted-tasks.ts";

const MAX_ENTRIES = 1_000;
const BATCH = 50;
/** The list in focus: the one whose reads make the cache stale. */
const FOCUSED: Topic = { topic: "tasks", workspace: "" };

type Entry = {
  value?: TaskSummary;
  pending?: boolean;
  failed?: boolean;
  stale?: boolean;
};

const keyFor = (group: string, id: string) => `${group}\u0000${id}`;

/** The ids a topic asks for, each once. */
function idsOf(topic: Topic): string[] {
  const raw = typeof topic.ids === "string" ? topic.ids : "";
  return [...new Set(raw.split(",").filter((id) => id !== ""))];
}

/** A Task of the list as a summary. */
function fromItem(item: ProductInboxItem): TaskSummary {
  return {
    id: item.conversationId,
    group_id: item.groupId,
    kind: item.kind,
    status: item.status,
    title: item.title,
    ...(item.archiveVersion === undefined ? {} : { updated_at: item.archiveVersion }),
    ...(item.archiveAvailability
      ? { archive_availability: item.archiveAvailability }
      : {}),
    ...(item.labels === undefined ? {} : { labels: item.labels }),
    ...(item.origin === undefined ? {} : { origin: item.origin }),
    ...(item.clientPlatform === undefined
      ? {}
      : { client_platform: item.clientPlatform }),
    ...(item.loop === undefined ? {} : { loop: item.loop }),
    ...(item.runStartedAt === undefined ? {} : { run_started_at: item.runStartedAt }),
  };
}

export class TaskSummaries {
  readonly #ctx: Ctx;
  readonly #entries = new Map<string, Entry>();
  readonly #queued = new Set<string>();
  /** Counts up on each invalidation: an answer to a request sent before it is dropped. */
  #generation = 0;
  #running = false;
  /** The live topics, by key. */
  readonly #shown = new Set<string>();
  #watch: Watch | null = null;
  /** The read of the list in focus last seen (`lastSyncedAt`); null before the first. */
  #seen: { readAt: number | undefined } | null = null;
  /** The list in focus by group and conversation, while it holds. */
  #projected: Map<string, ProductInboxItem> | null = null;
  #accountKey: string | null = null;
  /** Tasks Comma's server does not keep: their facts are read where they are kept, never asked of it. */
  hosted: HostedTasks | undefined;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("taskSummaries", {
      start: (topic) => {
        this.#shown.add(JSON.stringify(topic));
        // The list in focus stays live while Tasks are shown from it, and each change of it reaches them.
        this.#watch ??= kernel.store.watch(FOCUSED, () => this.#listChanged());
        this.#listChanged();
        this.#ask(topic);
      },
      stop: (topic) => {
        this.#shown.delete(JSON.stringify(topic));
        if (this.#shown.size > 0) return;
        this.#watch?.drop();
        this.#watch = null;
        this.#seen = null;
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account knew is shown to another.
      this.#entries.clear();
      this.#queued.clear();
      this.#generation++;
      this.#seen = null;
      this.#projected = null;
      this.#changed();
      for (const topic of this.#topics()) this.#ask(topic);
    });
  }

  /** Every cached fact is stale: those shown are read again. */
  invalidate(): void {
    this.#stale();
    this.#changed();
    for (const topic of this.#topics()) this.#ask(topic);
  }

  /** Marks every fact stale, forgets the ones not known yet, and drops the answers to requests already sent. */
  #stale(): void {
    this.#generation++;
    for (const [key, entry] of this.#entries) {
      if (entry.value) this.#entries.set(key, { value: entry.value, stale: true });
      else this.#entries.delete(key);
    }
    this.#queued.clear();
  }

  /** A fact the server answered elsewhere (an archive): kept unless the cache has a newer one. */
  record(value: TaskSummary): void {
    if (this.#put(value)) this.#changed();
  }

  #put(value: TaskSummary): boolean {
    const key = keyFor(value.group_id, value.id);
    const previous = this.#entries.get(key)?.value;
    if (previous && (previous.updated_at ?? 0) >= (value.updated_at ?? 0)) return false;
    if (!previous && this.#entries.size >= MAX_ENTRIES) return false;
    this.#entries.set(key, { value });
    return true;
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((t) => t.topic === "taskSummaries");
  }

  #changed(): void {
    this.#ctx.kernel.store.invalidateAll((t) => t.topic === "taskSummaries");
  }

  #item(group: string, id: string): ProductInboxItem | undefined {
    if (!this.#projected) {
      const list = this.#ctx.kernel.store.get(FOCUSED) as
        | ProductInboxListResult
        | null
        | undefined;
      this.#projected = new Map(
        (list?.items ?? []).map((item) => [
          keyFor(item.groupId, item.conversationId),
          item,
        ])
      );
    }
    return this.#projected.get(keyFor(group, id));
  }

  /** The list in focus changed: a new read of it makes the cache stale; its versioned Tasks are kept. */
  #listChanged(): void {
    this.#projected = null;
    const list = this.#ctx.kernel.store.get(FOCUSED) as
      | ProductInboxListResult
      | null
      | undefined;
    if (list) {
      // The first read seen is what the cache started from.
      const read = this.#seen !== null && this.#seen.readAt !== list.lastSyncedAt;
      this.#seen = { readAt: list.lastSyncedAt };
      if (read) this.#stale();
    }
    // What the list says of a shown Task with a version is the server's: it outlives the list's page.
    for (const topic of this.#topics()) {
      const group = String(topic.group);
      for (const id of idsOf(topic)) {
        const item = this.#item(group, id);
        if (item?.archiveVersion) this.#put(fromItem(item));
      }
    }
    this.#changed();
    for (const topic of this.#topics()) this.#ask(topic);
  }

  /** Asks for the shown Tasks the list does not have with a version. */
  #ask(topic: Topic): void {
    if (topic.peek === "1") return;
    const group = String(topic.group);
    if (!group) return;
    for (const id of idsOf(topic))
      if (!this.hosted?.owns(id) && !this.#item(group, id)?.archiveVersion)
        this.#request(group, id);
  }

  #request(group: string, id: string): void {
    const key = keyFor(group, id);
    const previous = this.#entries.get(key);
    if (
      (previous && !previous.stale) ||
      (!previous && this.#entries.size >= MAX_ENTRIES)
    )
      return;
    this.#entries.set(key, { ...previous, stale: false, pending: true });
    this.#queued.add(key);
    if (this.#running) return;
    this.#running = true;
    this.#ctx.runner.fork(
      this.#drain().pipe(Effect.ensuring(Effect.sync(() => (this.#running = false))))
    );
  }

  /** Sends what is queued, one request at a time, each at most 50 Tasks of one Group. */
  #drain(): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      // What the same moment asks goes in one request.
      yield* ctx.host.yieldTurn;
      while (this.#queued.size > 0) {
        const first = this.#queued.values().next().value!;
        const group = first.split("\u0000")[0]!;
        const keys = [...this.#queued]
          .filter((key) => key.startsWith(`${group}\u0000`))
          .slice(0, BATCH);
        for (const key of keys) this.#queued.delete(key);
        const generation = this.#generation;
        const ids = keys.map((key) => key.split("\u0000")[1]!);
        const answer = yield* ctx.session.account().pipe(
          Effect.flatMap((account) =>
            ctx.api.request(
              account,
              "GET",
              `${route`/v1/comma/groups/${group}/task-summaries`}?ids=${encodeURIComponent(ids.join(","))}`,
              taskPageSchema(taskSummarySchema)
            )
          ),
          Effect.option
        );
        if (generation !== this.#generation) continue;
        // A Task the answer leaves out (or a failed request) shows what is known, without its archive permission.
        for (const key of keys)
          this.#entries.set(key, {
            ...this.#entries.get(key),
            pending: false,
            failed: true,
          });
        if (Option.isSome(answer))
          for (const value of answer.value.data) {
            const key = keyFor(group, value.id);
            if (!keys.includes(key) || value.group_id !== group) continue;
            const previous = this.#entries.get(key)?.value;
            if (!previous || (value.updated_at ?? 0) >= (previous.updated_at ?? 0))
              this.#entries.set(key, { value });
          }
        this.#changed();
      }
    });
  }

  /** A Task's fact as shown: the list's when it is as new as the cache's, else the cache's. */
  #summary(group: string, id: string): TaskSummary | undefined {
    const entry = this.#entries.get(keyFor(group, id));
    let cached = entry?.value;
    if (cached && (entry?.stale || entry?.pending || entry?.failed)) {
      const { archive_availability: _, ...unconfirmed } = cached;
      cached = unconfirmed;
    }
    const item = this.#item(group, id);
    const listed = item ? fromItem(item) : undefined;
    return listed && (!cached || (listed.updated_at ?? 0) >= (cached.updated_at ?? 0))
      ? listed
      : cached;
  }

  /** A Task Comma's server does not keep, as where it is kept says it. */
  #hosted(group: string, id: string): TaskSummary | null {
    const account = this.#ctx.session.current();
    return account && this.hosted?.owns(id)
      ? this.hosted.summary(account, group, id)
      : null;
  }

  /** The Tasks Comma's server does not keep changed: the topics that show one compute again. */
  hostedChanged(): void {
    const hosted = this.hosted;
    if (!hosted) return;
    this.#ctx.kernel.store.invalidateAll(
      (t) => t.topic === "taskSummaries" && idsOf(t).some((id) => hosted.owns(id))
    );
  }

  #value(topic: Topic): TaskSummariesValue {
    const group = String(topic.group);
    return {
      summaries: idsOf(topic).flatMap((id) => {
        const summary = this.#hosted(group, id) ?? this.#summary(group, id);
        return summary
          ? [
              {
                ...summary,
                status_bucket: taskStatusBucket(summary.status),
                status_failed: taskStatusFailed(summary.status),
              },
            ]
          : [];
      }),
    };
  }
}
