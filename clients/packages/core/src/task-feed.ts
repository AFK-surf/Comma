// A workspace's Task Feed (chronological Task milestone & outcome stream). Each `(workspace, attention)` feed is kept
// on the device per account (`doc` "task-feed:<workspace>:<all|attention>"), and the reader's watermark is kept in
// `doc` "task-feed-seen:<workspace>", so opening the feed shows cached entries at once with zero flicker. While a UI
// shows a feed, the core reads its first page again, keeps one group event stream open per shown workspace, and reads
// the feed again whenever that stream (or `tasks` refresh) says the workspace's Tasks changed.
//
// Bounds: one read per (workspace, attention) in flight (scheduler key), 5 s timeout per request; one SSE stream per
// shown workspace reconnected with 1, 2, 4, 8, 15 s backoff; failed reads retried with the same backoff while shown;
// single-task activity history bounded to 50 pages of 100 messages. No polling.
import type { ChatMessage, ChatTaskActivity } from "@comma/chat-contract";
import { taskStatusBucket } from "@comma/i18n";
import {
  CoreError,
  LastMade,
  madeOnce,
  Priority,
  topicKey,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { normalizeServerMessages } from "./chat/model/conversationChannel.ts";
import {
  taskActivity,
  withLoopRuns,
  type TaskLoopRun,
} from "./chat/model/taskActivity.ts";
import { commaMessagePageSchema } from "./comma/api-schemas.ts";
import {
  taskFeedPageSchema,
  taskListEventSchema,
  type RawTaskFeedEntry,
} from "./comma/schemas.ts";
import {
  TOPIC_SPECS,
  type TaskFeedEntry,
  type TaskFeedErrorCode,
  type TaskFeedFile,
  type TaskFeedMedia,
  type TaskFeedMilestone,
  type TaskFeedSnapshot,
  type TaskWorkspace,
} from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import { readEvents } from "./sse.ts";
import type { Tasks } from "./tasks.ts";
import type { Workspaces } from "./workspaces.ts";

const LIMIT = 25;
const TIMEOUT_MS = 5_000;
const RETRY_MS = [1_000, 2_000, 4_000, 8_000, 15_000];
const ACTIVITY_PAGE_LIMIT = 100;
const MAX_ACTIVITY_PAGES = 50;

const EMPTY_ENTRIES: readonly TaskFeedEntry[] = [];

type AttentionKey = "all" | "attention";

type FeedPage = {
  entries: TaskFeedEntry[];
  hasMore: boolean;
  nextCursor?: string | undefined;
};

type KeptFeed = {
  groupId: string;
  pages: FeedPage[];
};

type SeenDoc = {
  at: number;
};

type FeedState = {
  live: boolean;
  error?: TaskFeedErrorCode;
  refreshedAt?: number;
  retry: number;
};

type StreamState = {
  streaming?: string;
};

const feedDoc = (workspace: string, attention: AttentionKey) =>
  `task-feed:${workspace}:${attention}`;
const seenDoc = (workspace: string) => `task-feed-seen:${workspace}`;
const stateKey = (workspace: string, attention: AttentionKey) =>
  `${workspace}:${attention}`;

function attentionKeyOf(value: unknown): AttentionKey {
  return value === "1" || value === true ? "attention" : "all";
}

function epochMs(at: number): number {
  return at > 0 && at < 10_000_000_000 ? at * 1_000 : at;
}

function feedEntry(raw: RawTaskFeedEntry): TaskFeedEntry {
  const milestones: TaskFeedMilestone[] = raw.milestones.map((m) => ({
    title: m.title,
    ...(m.at != null ? { at: epochMs(m.at) } : {}),
    ...(m.message_id ? { messageId: m.message_id } : {}),
  }));
  const media: TaskFeedMedia[] = raw.media.map((m) => ({
    attachmentId: m.attachment_id,
    ...(m.mime_type ? { mimeType: m.mime_type } : {}),
    ...(m.width != null ? { width: m.width } : {}),
    ...(m.height != null ? { height: m.height } : {}),
    ...(m.filename ? { filename: m.filename } : {}),
  }));
  const files: TaskFeedFile[] = raw.files.map((f) => ({
    name: f.name,
    ...(f.mime_type ? { mimeType: f.mime_type } : {}),
  }));
  return {
    id: raw.id,
    conversationId: raw.conversation_id,
    groupId: raw.group_id,
    clusterKey: raw.cluster_key,
    triggerKind: raw.trigger_kind,
    ...(raw.trigger_text != null ? { triggerText: raw.trigger_text } : {}),
    taskTitle: raw.task_title,
    taskStatus: raw.task_status,
    statusBucket: taskStatusBucket(raw.task_status),
    taskUpdatedAt: epochMs(raw.task_updated_at),
    ...(raw.review_version != null ? { reviewVersion: raw.review_version } : {}),
    ...(raw.origin != null ? { origin: raw.origin } : {}),
    isLoop: raw.is_loop,
    ...(raw.loop_kind != null ? { loopKind: raw.loop_kind } : {}),
    occurredAt: epochMs(raw.occurred_at),
    milestones,
    milestoneCount: raw.milestone_count,
    ...(raw.outcome_message_id != null
      ? { outcomeMessageId: raw.outcome_message_id }
      : {}),
    ...(raw.outcome_text != null ? { outcomeText: raw.outcome_text } : {}),
    media,
    files,
    ...(raw.pull_request ? { pullRequest: raw.pull_request } : {}),
  };
}

function errorCode(error: CoreError): TaskFeedErrorCode {
  if (error.code === "network" || error.code === "timeout")
    return "network_unavailable";
  if (
    error.code === "signed_out" ||
    error.status === 401 ||
    error.code === "session_changed" ||
    error.code === "session_product_lease_unavailable"
  )
    return "session_product_lease_unavailable";
  if (error.code === "bad_response") return "protocol_mismatch";
  if (error.code === "storage") return "utility_unavailable";
  return "unknown";
}

function dedupeEntries(entries: readonly TaskFeedEntry[]): TaskFeedEntry[] {
  const seenIds = new Set<string>();
  const seenConversations = new Set<string>();
  const result: TaskFeedEntry[] = [];
  for (const entry of entries) {
    if (seenIds.has(entry.id) || seenConversations.has(entry.conversationId)) {
      continue;
    }
    seenIds.add(entry.id);
    seenConversations.add(entry.conversationId);
    result.push(entry);
  }
  return result;
}

function refreshed(pages: readonly FeedPage[], first: FeedPage): FeedPage[] {
  const firstEntries = dedupeEntries(first.entries);
  const normalizedFirst =
    firstEntries.length === first.entries.length
      ? first
      : { ...first, entries: firstEntries };
  if (pages.length <= 1) return [normalizedFirst];
  const seenIds = new Set(firstEntries.map((entry) => entry.id));
  const seenConversations = new Set(firstEntries.map((entry) => entry.conversationId));
  return [
    normalizedFirst,
    ...pages.slice(1).map((page) => {
      const entries: TaskFeedEntry[] = [];
      for (const entry of page.entries) {
        if (seenIds.has(entry.id) || seenConversations.has(entry.conversationId)) {
          continue;
        }
        seenIds.add(entry.id);
        seenConversations.add(entry.conversationId);
        entries.push(entry);
      }
      return entries.length === page.entries.length ? page : { ...page, entries };
    }),
  ];
}

function appended(pages: readonly FeedPage[], next: FeedPage): FeedPage[] {
  const seenIds = new Set<string>();
  const seenConversations = new Set<string>();
  for (const page of pages) {
    for (const entry of page.entries) {
      seenIds.add(entry.id);
      seenConversations.add(entry.conversationId);
    }
  }
  const entries: TaskFeedEntry[] = [];
  for (const entry of next.entries) {
    if (seenIds.has(entry.id) || seenConversations.has(entry.conversationId)) {
      continue;
    }
    seenIds.add(entry.id);
    seenConversations.add(entry.conversationId);
    entries.push(entry);
  }
  return [...pages, { ...next, entries }];
}

const flattenedEntries = madeOnce(
  (pages: readonly FeedPage[]): readonly TaskFeedEntry[] => {
    if (pages.length === 0) return EMPTY_ENTRIES;
    if (pages.length === 1) return pages[0]!.entries;
    return pages.flatMap((page) => page.entries);
  }
);

export class TaskFeed {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #tasks: Tasks;
  readonly #live: Live;
  readonly #kept: Live;
  readonly #keptWorkspaces = new Set<string>();
  readonly #states = new Map<string, FeedState>();
  readonly #streams = new Map<string, StreamState>();
  readonly #etags = new Map<string, { etag: string; value: unknown }>();
  readonly #made = new LastMade<string, TaskFeedSnapshot>(TOPIC_SPECS.taskFeed ?? null);
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces, tasks: Tasks) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#tasks = tasks;
    this.#live = new Live(ctx.runner);
    this.#kept = new Live(ctx.runner);

    ctx.kernel.source("taskFeed", {
      evictAfterMs: 5_000,
      start: (topic) => this.#live.run(topic, this.#keep(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#made.delete(topicKey(topic));
        this.#settleKept();
      },
      compute: (topic): Value => ({
        ok: this.#made.of(topicKey(topic), this.#value(topic)),
      }),
    });

    workspaces.onChange(() => this.#invalidate());

    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#kept.stopAll();
      this.#keptWorkspaces.clear();
      this.#states.clear();
      this.#streams.clear();
      this.#etags.clear();
      this.#made.clear();
      for (const topic of ctx.kernel.store.liveTopics()) {
        if (topic.topic !== "taskFeed") continue;
        this.#live.stop(topic);
        ctx.kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic));
      }
    });

    ctx.kernel.calls({
      "taskFeed.refresh": {
        run: (p) => {
          const params = p as { workspace?: unknown; attention?: unknown } | null;
          const attention = attentionKeyOf(params?.attention);
          return this.#account().pipe(
            Effect.flatMap((account) =>
              this.#refresh(
                account,
                this.#workspaceIdOf(account, params?.workspace),
                attention,
                Priority.asked
              )
            ),
            Effect.as(null)
          );
        },
      },
      "taskFeed.loadMore": {
        run: (p) => {
          const params = p as {
            workspace?: unknown;
            attention?: unknown;
            cursor?: unknown;
          } | null;
          if (typeof params?.cursor !== "string" || params.cursor.trim() === "")
            throw CoreError.invalid("cursor is required");
          const cursor = params.cursor;
          const attention = attentionKeyOf(params.attention);
          return this.#account().pipe(
            Effect.flatMap((account) =>
              this.#loadMore(
                account,
                this.#workspaceIdOf(account, params.workspace),
                attention,
                cursor
              )
            ),
            Effect.as(null)
          );
        },
      },
      "taskFeed.markSeen": {
        run: (p) => {
          const params = p as { workspace?: unknown; at?: unknown } | null;
          if (
            typeof params?.at !== "number" ||
            !Number.isFinite(params.at) ||
            params.at < 0
          )
            throw CoreError.invalid("at must be a finite non-negative number");
          const at = params.at;
          return this.#account().pipe(
            Effect.map((account) => {
              const workspace = this.#workspaceIdOf(account, params.workspace);
              if (!workspace) throw CoreError.invalid("workspace is required");
              const prev = this.#seenAt(account, workspace);
              const next = prev !== undefined ? Math.max(prev, at) : at;
              if (prev === undefined || next > prev) {
                account.putDoc(
                  seenDoc(workspace),
                  { at: next } satisfies SeenDoc,
                  ctx.now()
                );
                this.#invalidate(workspace);
              }
              return { lastSeenAt: next };
            })
          );
        },
      },
      "taskFeed.activity": {
        run: (p) => {
          const params = p as { groupId?: unknown; conversationId?: unknown } | null;
          if (
            typeof params?.groupId !== "string" ||
            !params.groupId ||
            typeof params.conversationId !== "string" ||
            !params.conversationId
          )
            throw CoreError.invalid("groupId and conversationId are required");
          const { groupId, conversationId } = params;
          return this.#account().pipe(
            Effect.flatMap((account) =>
              this.#activity(account, groupId, conversationId)
            )
          );
        },
      },
    });
  }

  /** Called when `tasks.focus` moves to another workspace: topics with no explicit workspace follow it. */
  focusChanged(): void {
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (topic.topic !== "taskFeed" || topic.workspace) continue;
      this.#live.stop(topic);
      this.#ctx.kernel.store.invalidate(topic);
      this.#live.run(topic, this.#keep(topic));
    }
    this.#settleKept();
  }

  /** Called when `tasks` refreshed a workspace: silently refreshes any shown Task Feed for that workspace. */
  changed(workspace: string): void {
    const account = this.#ctx.session.current();
    if (!account) return;
    const attentions = this.#shownAttentions(account, workspace);
    for (const attention of attentions) {
      this.#ctx.runner.fork(
        this.#refresh(account, workspace, attention, Priority.background).pipe(
          Effect.ignore
        )
      );
    }
  }

  #account(): Effect.Effect<Account, CoreError> {
    return this.#ctx.session.account();
  }

  #state(workspace: string, attention: AttentionKey): FeedState {
    const k = stateKey(workspace, attention);
    let state = this.#states.get(k);
    if (!state) {
      state = { live: false, retry: 0 };
      this.#states.set(k, state);
    }
    return state;
  }

  #streamState(workspace: string): StreamState {
    let state = this.#streams.get(workspace);
    if (!state) {
      state = {};
      this.#streams.set(workspace, state);
    }
    return state;
  }

  #workspaceOf(account: Account, wanted: unknown): TaskWorkspace | null {
    const name = typeof wanted === "string" ? wanted : "";
    return this.#tasks.workspace(account, name);
  }

  #workspaceIdOf(account: Account, wanted: unknown): string {
    const resolved = this.#workspaceOf(account, wanted);
    if (resolved) return resolved.id;
    return typeof wanted === "string" ? wanted : "";
  }

  #keptFeed(
    account: Account,
    workspace: string,
    attention: AttentionKey
  ): KeptFeed | undefined {
    return account.doc<KeptFeed>(feedDoc(workspace, attention))?.value;
  }

  #putKept(
    account: Account,
    workspace: string,
    attention: AttentionKey,
    kept: KeptFeed
  ): boolean {
    return account.putDoc(feedDoc(workspace, attention), kept, this.#ctx.now());
  }

  #seenAt(account: Account, workspace: string): number | undefined {
    return account.doc<SeenDoc>(seenDoc(workspace))?.value.at;
  }

  #invalidate(workspace?: string): void {
    const account = this.#ctx.session.current();
    this.#ctx.kernel.store.invalidateAll((topic) => {
      if (topic.topic !== "taskFeed") return false;
      if (workspace === undefined || !account) return true;
      return this.#workspaceIdOf(account, topic.workspace) === workspace;
    });
  }

  #shownAttentions(account: Account, workspace: string): Set<AttentionKey> {
    const out = new Set<AttentionKey>();
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (topic.topic !== "taskFeed") continue;
      if (this.#workspaceIdOf(account, topic.workspace) === workspace) {
        out.add(attentionKeyOf(topic.attention));
      }
    }
    return out;
  }

  #shown(account: Account, workspace: string): boolean {
    return this.#shownAttentions(account, workspace).size > 0;
  }

  static #keptOf(workspace: string): Topic {
    return { topic: "taskFeed", workspace, kept: "1" };
  }

  #keepFor(workspace: string, work: Effect.Effect<unknown, unknown>): void {
    this.#keptWorkspaces.add(workspace);
    this.#kept.run(TaskFeed.#keptOf(workspace), work);
  }

  #settleKept(): void {
    const account = this.#ctx.session.current();
    for (const workspace of this.#keptWorkspaces) {
      if (account && this.#shown(account, workspace)) continue;
      this.#keptWorkspaces.delete(workspace);
      this.#kept.stop(TaskFeed.#keptOf(workspace));
    }
  }

  #keep(topic: Topic): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      let workspace = this.#workspaceIdOf(account.value, topic.workspace);
      if (!workspace) {
        yield* this.#workspaces.refresh().pipe(Effect.ignore);
        workspace = this.#workspaceIdOf(account.value, topic.workspace);
      }
      const attention = attentionKeyOf(topic.attention);
      const state = this.#state(workspace, attention);
      const stream = this.#streamState(workspace);
      const fresh =
        state.live &&
        state.error === undefined &&
        state.refreshedAt !== undefined &&
        this.#ctx.now() - state.refreshedAt < 15_000;
      if (fresh) {
        const ws = this.#workspaceOf(account.value, workspace);
        if (ws) this.#stream(account.value, ws);
      } else if (!(state.live && stream.streaming && state.error === undefined)) {
        yield* this.#refresh(account.value, workspace, attention, Priority.shown).pipe(
          Effect.ignore
        );
      }
      return yield* Effect.never;
    });
  }

  #refresh(
    account: Account,
    wanted: string,
    attention: AttentionKey,
    priority: number,
    streamed = false
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    const key = `${account.dbName}:${feedDoc(wanted, attention)}`;
    let resolvedWorkspaceId = wanted;
    const read = Effect.gen({ self: this }, function* () {
      let workspace = this.#workspaceOf(account, wanted);
      if (!workspace) {
        yield* this.#workspaces.refresh(priority);
        workspace = this.#workspaceOf(account, wanted);
      }
      if (!workspace) {
        this.#state(wanted, attention).live = true;
        this.#invalidate();
        return;
      }
      resolvedWorkspaceId = workspace.id;
      const query =
        attention === "attention" ? `limit=${LIMIT}&attention=1` : `limit=${LIMIT}`;
      const path = `${route`/v1/comma/groups/${workspace.group_id}/task-feed`}?${query}`;
      const page = yield* this.#get(account, path, taskFeedPageSchema);
      if (page.entries.some((entry) => entry.group_id !== workspace.group_id))
        return yield* Effect.fail(
          new CoreError("bad_response", "a task feed entry of another group")
        );
      if (page.has_more && !page.next_cursor)
        return yield* Effect.fail(
          new CoreError("bad_response", "a next feed page without its cursor")
        );
      const kept = this.#keptFeed(account, workspace.id, attention);
      const first: FeedPage = {
        entries: page.entries.map(feedEntry),
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
      if (
        !this.#putKept(account, workspace.id, attention, {
          groupId: workspace.group_id,
          pages: refreshed(kept?.pages ?? [], first),
        })
      )
        return;
      const state = this.#state(workspace.id, attention);
      state.live = true;
      state.refreshedAt = this.#ctx.now();
      delete state.error;
      state.retry = 0;
      this.#invalidate(workspace.id);
      this.#stream(account, workspace);
    }).pipe(
      Effect.tapError((error) =>
        Effect.sync(() => {
          if (account.closed) return;
          const state = this.#state(resolvedWorkspaceId, attention);
          state.error = errorCode(error);
          this.#invalidate(resolvedWorkspaceId);
          if (!streamed && error.status !== 404) {
            const delay = RETRY_MS[Math.min(state.retry, RETRY_MS.length - 1)]!;
            state.retry++;
            this.#later(resolvedWorkspaceId, attention, delay);
          }
        })
      )
    );
    return ctx.scheduler.ask(API_LANE, key, priority, read);
  }

  #later(workspace: string, attention: AttentionKey, ms: number): void {
    const account = this.#ctx.session.current();
    if (!account || !this.#shownAttentions(account, workspace).has(attention)) return;
    this.#keepFor(
      workspace,
      Effect.sleep(ms).pipe(
        Effect.andThen(
          this.#refresh(account, workspace, attention, Priority.background)
        ),
        Effect.ignore
      )
    );
  }

  #get<T>(
    account: Account,
    path: string,
    schema: import("zod").ZodType<T>
  ): Effect.Effect<T, CoreError> {
    const held = this.#etags.get(path);
    return this.#ctx.api.get(account, path, schema, held?.etag, TIMEOUT_MS).pipe(
      Effect.flatMap((answer) => {
        if (answer.notModified)
          return held
            ? Effect.succeed(held.value as T)
            : Effect.fail(new CoreError("bad_response", "304 without a kept answer"));
        if (answer.etag) {
          if (this.#etags.size >= 64)
            this.#etags.delete(this.#etags.keys().next().value!);
          this.#etags.set(path, { etag: answer.etag, value: answer.value });
        }
        return Effect.succeed(answer.value);
      })
    );
  }

  #loadMore(
    account: Account,
    wanted: string,
    attention: AttentionKey,
    cursor: string
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const workspace = this.#workspaceOf(account, wanted);
      if (!workspace) return;
      const kept = this.#keptFeed(account, workspace.id, attention);
      const query =
        attention === "attention"
          ? `limit=${LIMIT}&cursor=${encodeURIComponent(cursor)}&attention=1`
          : `limit=${LIMIT}&cursor=${encodeURIComponent(cursor)}`;
      const path = `${route`/v1/comma/groups/${workspace.group_id}/task-feed`}?${query}`;
      const page = yield* ctx.api.request(
        account,
        "GET",
        path,
        taskFeedPageSchema,
        undefined,
        TIMEOUT_MS
      );
      if (page.entries.some((entry) => entry.group_id !== workspace.group_id))
        return yield* Effect.fail(
          new CoreError("bad_response", "a task feed entry of another group")
        );
      if (page.has_more && !page.next_cursor)
        return yield* Effect.fail(
          new CoreError("bad_response", "a next feed page without its cursor")
        );
      const next: FeedPage = {
        entries: page.entries.map(feedEntry),
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
      const current = this.#keptFeed(account, workspace.id, attention);
      // If a concurrent refresh moved the feed's tail away from this cursor, drop the stale page.
      if (kept && current?.pages.at(-1)?.nextCursor !== cursor) return;
      this.#putKept(account, workspace.id, attention, {
        groupId: workspace.group_id,
        pages: appended(current?.pages ?? [], next),
      });
      const state = this.#state(workspace.id, attention);
      state.live = true;
      delete state.error;
      this.#invalidate(workspace.id);
    }).pipe(
      Effect.mapError(
        (error) => new CoreError(errorCode(error), error.message, error.status)
      ),
      (read) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${feedDoc(wanted, attention)}:more:${cursor}`,
          Priority.asked,
          read
        )
    );
  }

  #stream(account: Account, workspace: TaskWorkspace): void {
    const streamState = this.#streamState(workspace.id);
    if (streamState.streaming === workspace.group_id) return;
    if (!this.#shown(account, workspace.id)) return;
    streamState.streaming = workspace.group_id;
    const ctx = this.#ctx;
    const path = route`/v1/comma/groups/${workspace.group_id}/conversations/events`;
    let lastVersion: string | undefined;
    let backoff = 0;
    const once = Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const body = yield* ctx.api.stream(account, path);
        backoff = 0;
        yield* readEvents(body, (value) =>
          Effect.gen({ self: this }, function* () {
            const event = taskListEventSchema.safeParse(value);
            if (!event.success) return;
            if (event.data.group_id !== workspace.group_id)
              return yield* Effect.fail(
                new CoreError("bad_response", "an event of another group")
              );
            if (
              event.data.type !== "conversation_list_invalidated" &&
              event.data.type !== "conversation_list_resync_required"
            )
              return;
            if (
              event.data.type !== "conversation_list_resync_required" &&
              event.data.version === lastVersion
            )
              return;
            lastVersion = event.data.version;
            const attentions = [...this.#shownAttentions(account, workspace.id)];
            for (const attention of attentions) {
              const read = yield* Effect.result(
                this.#refresh(account, workspace.id, attention, Priority.shown, true)
              );
              if (Result.isFailure(read)) return yield* Effect.fail(read.failure);
            }
          })
        );
      })
    );
    this.#keepFor(
      workspace.id,
      Effect.gen(function* () {
        for (;;) {
          const ended = yield* Effect.result(once);
          if (account.closed) return;
          if (Result.isFailure(ended)) lastVersion = undefined;
          yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
          backoff++;
        }
      }).pipe(Effect.ensuring(Effect.sync(() => void delete streamState.streaming)))
    );
  }

  #activity(
    account: Account,
    groupId: string,
    conversationId: string
  ): Effect.Effect<ChatTaskActivity | null, CoreError> {
    const ctx = this.#ctx;
    const read = Effect.gen(function* () {
      let allMessages: ChatMessage[] = [];
      let runs: readonly TaskLoopRun[] = [];
      let before: number | undefined;
      for (let pages = 0; pages < MAX_ACTIVITY_PAGES; pages++) {
        const params = new URLSearchParams({
          limit: String(ACTIVITY_PAGE_LIMIT),
          view: "activity",
        });
        if (before !== undefined) params.set("before", String(before));
        const path = `${route`/v1/comma/groups/${groupId}/conversations/${conversationId}/messages`}?${params}`;
        const page = yield* ctx.api.request(
          account,
          "GET",
          path,
          commaMessagePageSchema,
          undefined,
          TIMEOUT_MS
        );
        if (before !== undefined && page.covered && page.covered.first >= before) break;
        const normalized = normalizeServerMessages(
          page.data,
          [],
          "agent_task",
          conversationId
        );
        allMessages = [...normalized, ...allMessages];
        runs = withLoopRuns(runs, page.data);
        if (!page.covered || page.has_older !== true) break;
        before = page.covered.first;
      }
      // Deduplicate by messageId while preserving chronological order.
      const seen = new Set<string>();
      const unique: ChatMessage[] = [];
      for (const message of allMessages) {
        if (seen.has(message.messageId)) continue;
        seen.add(message.messageId);
        unique.push(message);
      }
      return taskActivity(unique, runs) ?? null;
    });
    return read;
  }

  #value(topic: Topic): TaskFeedSnapshot {
    const account = this.#ctx.session.current();
    if (!account) {
      return {
        workspaceId: null,
        groupId: null,
        entries: EMPTY_ENTRIES,
        hasMore: false,
        loaded: false,
        source: "unavailable",
        errorCode: "session_product_lease_unavailable",
      };
    }
    const workspace = this.#workspaceOf(account, topic.workspace);
    const workspaceId =
      workspace?.id ??
      (typeof topic.workspace === "string" && topic.workspace ? topic.workspace : null);
    const attention = attentionKeyOf(topic.attention);
    const kept = workspaceId
      ? this.#keptFeed(account, workspaceId, attention)
      : undefined;
    const state = this.#state(workspaceId ?? "", attention);
    const lastSeenAt = workspaceId ? this.#seenAt(account, workspaceId) : undefined;
    const groupId = workspace?.group_id ?? kept?.groupId ?? null;
    const seenField = lastSeenAt !== undefined ? { lastSeenAt } : {};

    if (!kept) {
      if (state.error) {
        return {
          workspaceId,
          groupId,
          entries: EMPTY_ENTRIES,
          hasMore: false,
          ...seenField,
          loaded: false,
          source: "error",
          errorCode: state.error,
        };
      }
      if (state.live) {
        return {
          workspaceId,
          groupId,
          entries: EMPTY_ENTRIES,
          hasMore: false,
          ...seenField,
          loaded: true,
          source: "live",
        };
      }
      return {
        workspaceId,
        groupId,
        entries: EMPTY_ENTRIES,
        hasMore: false,
        ...seenField,
        loaded: false,
        source: "cache",
      };
    }

    const last = kept.pages.at(-1);
    const hasMore = last?.hasMore === true;
    const nextCursor = hasMore && last?.nextCursor ? last.nextCursor : undefined;
    return {
      workspaceId,
      groupId,
      entries: flattenedEntries(kept.pages),
      hasMore,
      ...(nextCursor ? { nextCursor } : {}),
      ...seenField,
      loaded: true,
      source: state.live && !state.error ? "live" : "cache",
      ...(state.error ? { errorCode: state.error } : {}),
    };
  }
}
