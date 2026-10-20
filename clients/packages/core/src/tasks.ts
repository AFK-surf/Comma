// A workspace's tasks and chats (the product inbox). The list is kept on the device per account (`doc`
// "tasks:<workspace>", its pages as read), so it shows at once, offline too; while a UI shows it the core reads it
// again, keeps one event stream open on the workspace's group, and reads it again whenever that stream says it
// changed. A person's archive or status change shows on the list before the server has it (`tasks.stage`) and ends
// once the server reports it, or a later version of the task.
//
// Bounds: one read per workspace in flight (the scheduler's key), each request given up after 5 s; one event stream per
// shown workspace, reconnected after 1, 2, 4… up to 15 s; a failed read without a stream to wake it is tried again
// after 1, 2, 4… up to 15 s. No polling of the list. The stream of the read's own group owns its recovery once the
// read has settled which group it is.
import { taskStatusBucket, taskStatusFailed } from "@comma/i18n";
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import {
  taskConversationSchema,
  taskListEventSchema,
  taskPageSchema,
  type TaskConversation,
} from "./comma/schemas.ts";
import { taskLoop } from "./comma/task-loop.ts";
import type {
  ProductInboxItem,
  ProductInboxListResult,
  TaskWorkspace,
} from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import { readEvents } from "./sse.ts";
import { WORKSPACES_DOC, type Workspaces } from "./workspaces.ts";

const LIMIT = 50;
const TIMEOUT_MS = 5_000;
const RETRY_MS = [1_000, 2_000, 4_000, 8_000, 15_000];

/** One page of a list as read. */
type Page = { items: ProductInboxItem[]; hasMore?: boolean; nextCursor?: string };
/** A workspace's list as kept. */
type Kept = { pages: Page[]; readAt: number };

type Stage = {
  groupId: string;
  conversationId: string;
  status: string;
  version?: number;
  /** The server accepted the change: only its own report of the task ends the stage. */
  settled: boolean;
};

/** What this run knows of a workspace's list beyond what is kept. */
type State = {
  /** Read from the server this run. */
  live: boolean;
  /** Why the last read failed. */
  error?: NonNullable<ProductInboxListResult["errorCode"]>;
  /** The group whose event stream is open, and so wakes a failed read. */
  streaming?: string;
  retry: number;
};

const doc = (workspace: string) => `tasks:${workspace}`;

/** Seconds as some servers send them, or milliseconds. */
function epochMs(at: number | undefined): number | undefined {
  if (at === undefined) return undefined;
  return at > 0 && at < 10_000_000_000 ? at * 1_000 : at;
}

export function taskItem(
  conversation: TaskConversation,
  workspace: TaskWorkspace
): ProductInboxItem {
  const loop = taskLoop(conversation.loop);
  return {
    ...(conversation.meeting ? { meetingPhase: conversation.meeting.phase } : {}),
    ...(conversation.archive_availability
      ? { archiveAvailability: conversation.archive_availability }
      : {}),
    ...(conversation.updated_at === undefined
      ? {}
      : { archiveVersion: conversation.updated_at }),
    conversationId: conversation.id,
    groupId: conversation.group_id,
    ...(conversation.freshness ? { freshness: conversation.freshness.state } : {}),
    id: `${conversation.group_id}:${conversation.id}`,
    kind: conversation.kind,
    ...(conversation.origin === undefined ? {} : { origin: conversation.origin }),
    labels: conversation.labels ?? [],
    ...(conversation.client_platform === undefined
      ? {}
      : { clientPlatform: conversation.client_platform }),
    ...(conversation.parent_message_id === undefined
      ? {}
      : { parentMessageId: conversation.parent_message_id }),
    ...(conversation.review_version
      ? { reviewVersion: conversation.review_version }
      : {}),
    ...(loop ? { loop, ...(loop.state === "ended" ? {} : { scheduled: true }) } : {}),
    ...(conversation.run_started_at === undefined
      ? {}
      : { runStartedAt: conversation.run_started_at }),
    source: "salix.conversation",
    status: conversation.status,
    title: conversation.title,
    updatedAt:
      epochMs(conversation.updated_at) ?? epochMs(conversation.created_at) ?? 0,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
  };
}

/** The item with the section its status folds into, as every client shows it. */
const withStatus = (item: ProductInboxItem): ProductInboxItem => ({
  ...item,
  statusBucket: taskStatusBucket(item.status),
  statusFailed: taskStatusFailed(item.status),
});

function errorCode(error: CoreError): NonNullable<ProductInboxListResult["errorCode"]> {
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

const stale = (item: ProductInboxItem): ProductInboxItem => ({
  ...item,
  freshness: "stale",
});

/** A first page read again: the rest of what was loaded stays, marked stale, without the tasks the new page has. */
function refreshed(pages: Page[], first: Page): Page[] {
  if (pages.length <= 1) return [first];
  const ids = new Set(first.items.map((item) => item.id));
  return [
    first,
    ...pages.slice(1).map((page) => ({
      ...page,
      items: page.items.filter((item) => !ids.has(item.id)).map(stale),
    })),
  ];
}

/** A next page: what it has leaves the earlier pages. */
function appended(pages: Page[], next: Page): Page[] {
  const ids = new Set(next.items.map((item) => item.id));
  return [
    ...pages.map((page) => ({
      ...page,
      items: page.items.filter((item) => !ids.has(item.id)),
    })),
    next,
  ];
}

export class Tasks {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #states = new Map<string, State>();
  /** Validators of the reads this run made, and what they answered: a 304 answers with it. */
  readonly #etags = new Map<string, { etag: string; value: unknown }>();
  readonly #stages = new Map<number, Stage>();
  #nextStage = 0;
  /** Told when a workspace's task stream says its stations changed their Tasks. */
  onStationTasksChanged: ((workspace: string) => void) | undefined;
  #focus: string | null = null;
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    ctx.kernel.source("tasks", {
      start: (topic) => this.#live.run(topic, this.#keep(topic)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    workspaces.onChange(() => this.#invalidate());
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#states.clear();
      this.#etags.clear();
      this.#stages.clear();
      this.#focus = ctx.session.current()?.meta<string>("tasksFocus") ?? null;
      if (key) ctx.runner.fork(this.#importLegacy());
      for (const topic of ctx.kernel.store.liveTopics()) {
        if (topic.topic !== "tasks") continue;
        this.#live.stop(topic);
        ctx.kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic));
      }
    });
    ctx.kernel.calls({
      "tasks.focus": {
        run: (p) =>
          Effect.sync(() => {
            const workspace = (p as { workspace?: unknown } | null)?.workspace;
            if (typeof workspace !== "string" || !workspace)
              throw CoreError.invalid("workspace is required");
            if (workspace === this.#focus) return null;
            this.#focus = workspace;
            ctx.session.current()?.setMeta("tasksFocus", workspace);
            // The lists that follow the focus show another workspace now.
            for (const topic of ctx.kernel.store.liveTopics()) {
              if (topic.topic !== "tasks" || topic.workspace) continue;
              this.#live.stop(topic);
              ctx.kernel.store.invalidate(topic);
              this.#live.run(topic, this.#keep(topic));
            }
            return null;
          }),
      },
      "tasks.refresh": {
        run: (p) => {
          const params = p as { workspace?: unknown; conversations?: unknown } | null;
          const conversations = Array.isArray(params?.conversations)
            ? [
                ...new Set(
                  params.conversations.filter(
                    (id): id is string => typeof id === "string" && id !== ""
                  )
                ),
              ]
                .slice(0, 50)
                .toSorted()
            : [];
          return this.#account().pipe(
            Effect.flatMap((account) =>
              this.#refresh(
                account,
                this.#workspaceOf(account, params?.workspace),
                Priority.asked,
                conversations
              )
            ),
            Effect.as(null)
          );
        },
      },
      "tasks.more": {
        run: (p) =>
          this.#account().pipe(
            Effect.flatMap((account) =>
              this.#more(
                account,
                this.#workspaceOf(
                  account,
                  (p as { workspace?: unknown } | null)?.workspace
                )
              )
            ),
            Effect.as(null)
          ),
      },
      "tasks.stage": {
        run: (p) =>
          Effect.sync(() => {
            const params = p as Partial<Stage> | null;
            if (
              typeof params?.groupId !== "string" ||
              typeof params.conversationId !== "string" ||
              typeof params.status !== "string"
            )
              throw CoreError.invalid(
                "groupId, conversationId and status are required"
              );
            return {
              stage: this.stage({
                groupId: params.groupId,
                conversationId: params.conversationId,
                status: params.status,
                ...(typeof params.version === "number"
                  ? { version: params.version }
                  : {}),
              }),
            };
          }),
      },
      "tasks.stage.settle": {
        run: (p) =>
          Effect.sync(() => {
            const params = p as { stage?: unknown; accepted?: unknown } | null;
            this.settle(params?.stage as number, params?.accepted === true);
            return null;
          }),
      },
    });
  }

  /** Shows a person's change on every list before the server has it; a newer one about the same task replaces it. */
  stage(change: Omit<Stage, "settled">): number {
    for (const [id, stage] of this.#stages)
      if (
        stage.groupId === change.groupId &&
        stage.conversationId === change.conversationId
      )
        this.#stages.delete(id);
    const id = ++this.#nextStage;
    this.#stages.set(id, { ...change, settled: false });
    this.#invalidate();
    return id;
  }

  /** Ends a stage: accepted, it lasts until the server's own report of the task; refused, at once. */
  settle(id: number, accepted: boolean): void {
    const stage = this.#stages.get(id);
    if (!stage) return;
    if (accepted) stage.settled = true;
    else this.#stages.delete(id);
    this.#invalidate();
  }

  /** Reads a workspace's list again now (`conversations` exactly): the one named, else the one in focus. */
  reread(workspace: string, conversations: string[]): Effect.Effect<void, CoreError> {
    return this.#account().pipe(
      Effect.flatMap((account) =>
        this.#refresh(
          account,
          this.#workspaceOf(account, workspace),
          Priority.asked,
          [...new Set(conversations)].slice(0, 50).toSorted()
        )
      )
    );
  }

  /** The workspace a surface means: the one named, else the one in focus, else the first known; null while none is. */
  workspace(account: Account, wanted: string): TaskWorkspace | null {
    const id = this.#workspaceOf(account, wanted);
    return this.#known(account).find((w) => w.id === id) ?? null;
  }

  /**
   * Brings over, once per account, the Tasks the host kept before the core (Electron's `comma.sqlite`), for the
   * workspaces the core has not read itself: the list shows offline on the first start after the update too.
   */
  #importLegacy(): Effect.Effect<void> {
    const ctx = this.#ctx;
    const legacy = ctx.host.legacyTasks?.bind(ctx.host);
    if (!legacy) return Effect.void;
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#account();
      if (account.meta<boolean>("legacyTasksImported")) return;
      const kept = yield* legacy(account.lease.audience, account.userId).pipe(
        Effect.mapError((e) => CoreError.host(e))
      );
      if (account.closed) return;
      for (const { workspace, conversations } of kept) {
        if (account.doc(doc(workspace.id))) continue;
        const items = conversations.flatMap((raw) => {
          const parsed = taskConversationSchema.safeParse(raw);
          return parsed.success && parsed.data.group_id === workspace.group_id
            ? [taskItem(parsed.data, workspace)]
            : [];
        });
        account.putDoc(
          doc(workspace.id),
          { pages: [{ items }], readAt: 0 } satisfies Kept,
          ctx.now()
        );
      }
      if (kept.length > 0 && !this.#workspaces.list(account))
        account.putDoc(
          WORKSPACES_DOC,
          kept.map((k) => k.workspace),
          0
        );
      account.setMeta("legacyTasksImported", true);
      this.#invalidate();
    }).pipe(Effect.ignore);
  }

  #invalidate(): void {
    this.#ctx.kernel.store.invalidateAll((topic) => topic.topic === "tasks");
  }

  #account(): Effect.Effect<Account, CoreError> {
    return this.#ctx.session.account();
  }

  #state(workspace: string): State {
    let state = this.#states.get(workspace);
    if (!state) {
      state = { live: false, retry: 0 };
      this.#states.set(workspace, state);
    }
    return state;
  }

  /** The workspaces the list knows: as last read (the workspaces' own list). */
  #known(account: Account): TaskWorkspace[] {
    return (this.#workspaces.list(account) ?? []).map((w) => ({
      group_id: w.group_id,
      id: w.id,
      name: w.name,
    }));
  }

  /** A topic's or call's workspace: its own, else the one in focus, else the first known; "" while none is known. */
  #workspaceOf(account: Account, wanted: unknown): string {
    const known = this.#known(account);
    const id = typeof wanted === "string" && wanted ? wanted : this.#focus;
    return (
      (id && known.find((w) => w.id === id)?.id) ||
      (typeof wanted === "string" && wanted) ||
      known[0]?.id ||
      ""
    );
  }

  /** Keeps a shown list current: read now, then as its stream says. */
  #keep(topic: Topic): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      let workspace = this.#workspaceOf(account.value, topic.workspace);
      if (!workspace) {
        // No workspace known yet: the list of them comes first.
        yield* this.#workspaces.refresh().pipe(Effect.ignore);
        workspace = this.#workspaceOf(account.value, topic.workspace);
      }
      yield* this.#refresh(account.value, workspace, Priority.shown, []).pipe(
        Effect.ignore
      );
      return yield* Effect.never;
    });
  }

  /** Reads a workspace's first page again (and `conversations` exactly), keeps it, and keeps its stream open. */
  #refresh(
    account: Account,
    wanted: string,
    priority: number,
    conversations: string[]
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    const key = `${account.dbName}:${doc(wanted)}${conversations.length ? `:${conversations.join(",")}` : ""}`;
    const read = Effect.gen({ self: this }, function* () {
      yield* this.#workspaces.refresh(priority);
      const known = this.#known(account);
      const workspace = known.find((w) => w.id === wanted) ?? known[0];
      if (!workspace) {
        this.#state(wanted).live = true;
        this.#invalidate();
        return;
      }
      const path = `${route`/v1/comma/groups/${workspace.group_id}/conversations`}?archive=include&limit=${LIMIT}`;
      const page = yield* this.#get(
        account,
        path,
        taskPageSchema(taskConversationSchema)
      );
      let data = page.data;
      if (conversations.length > 0) {
        const exact = yield* this.#get(
          account,
          `${route`/v1/comma/groups/${workspace.group_id}/task-summaries`}?ids=${encodeURIComponent(conversations.join(","))}`,
          taskPageSchema(taskConversationSchema)
        );
        const ids = new Set(conversations);
        data = [...data.filter((c) => !ids.has(c.id)), ...exact.data];
      }
      if (data.some((c) => c.group_id !== workspace.group_id))
        return yield* Effect.fail(
          new CoreError("bad_response", "a conversation of another group")
        );
      if (page.has_more === true && !page.next_cursor)
        return yield* Effect.fail(
          new CoreError("bad_response", "a next page without its cursor")
        );
      const first: Page = {
        items: data.map((c) => taskItem(c, workspace)),
        ...(page.has_more === undefined ? {} : { hasMore: page.has_more }),
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
      const kept = account.doc<Kept>(doc(workspace.id))?.value;
      if (
        !account.putDoc(
          doc(workspace.id),
          { pages: refreshed(kept?.pages ?? [], first), readAt: ctx.now() },
          ctx.now()
        )
      )
        return;
      const state = this.#state(workspace.id);
      state.live = true;
      delete state.error;
      state.retry = 0;
      this.#invalidate();
      this.#stream(account, workspace);
    }).pipe(
      Effect.tapError((error) =>
        Effect.sync(() => {
          if (account.closed) return;
          const state = this.#state(wanted);
          state.error = errorCode(error);
          this.#invalidate();
          // A stream on the workspace's group wakes the list again; without one, try again after a while.
          if (!state.streaming) {
            const delay = RETRY_MS[Math.min(state.retry, RETRY_MS.length - 1)]!;
            state.retry++;
            this.#later(wanted, delay);
          }
        })
      )
    );
    return ctx.scheduler.ask(API_LANE, key, priority, read);
  }

  /** A read after `ms`, in the fiber of the topics that show the workspace (gone with them). */
  #later(workspace: string, ms: number): void {
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (topic.topic !== "tasks") continue;
      const account = this.#ctx.session.current();
      if (!account || this.#workspaceOf(account, topic.workspace) !== workspace)
        continue;
      this.#live.run(
        topic,
        Effect.sleep(ms).pipe(
          Effect.andThen(this.#refresh(account, workspace, Priority.background, [])),
          Effect.ignore
        )
      );
      return;
    }
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

  /** The next page of a workspace's list, after what is kept. */
  #more(account: Account, wanted: string): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const workspace = this.#known(account).find((w) => w.id === wanted);
      const kept = account.doc<Kept>(doc(wanted))?.value;
      const cursor = kept?.pages.at(-1)?.nextCursor;
      if (!workspace || !kept || !cursor) return;
      const path = `${route`/v1/comma/groups/${workspace.group_id}/conversations`}?archive=include&limit=${LIMIT}&cursor=${encodeURIComponent(cursor)}`;
      const page = yield* ctx.api.request(
        account,
        "GET",
        path,
        taskPageSchema(taskConversationSchema),
        undefined,
        TIMEOUT_MS
      );
      const next: Page = {
        items: page.data.map((c) => taskItem(c, workspace)),
        ...(page.has_more === undefined ? {} : { hasMore: page.has_more }),
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
      // The list moved on meanwhile (read again from its start): this page is not its next one any more.
      if (account.doc<Kept>(doc(wanted))?.value.pages.at(-1)?.nextCursor !== cursor)
        return;
      account.putDoc(
        doc(wanted),
        { pages: appended(kept.pages, next), readAt: kept.readAt },
        ctx.now()
      );
      this.#invalidate();
    }).pipe(
      // Said as the list says it (its error codes), for the page that asked.
      Effect.mapError(
        (error) => new CoreError(errorCode(error), error.message, error.status)
      ),
      (read) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${doc(wanted)}:more`,
          Priority.asked,
          read
        )
    );
  }

  /** Keeps the workspace's group's event stream open while the list is shown: each change it says reads the list again. */
  #stream(account: Account, workspace: TaskWorkspace): void {
    const state = this.#state(workspace.id);
    if (state.streaming === workspace.group_id) return;
    const topic = this.#ctx.kernel.store
      .liveTopics()
      .find(
        (t) =>
          t.topic === "tasks" &&
          this.#workspaceOf(account, t.workspace) === workspace.id
      );
    if (!topic) return;
    state.streaming = workspace.group_id;
    const ctx = this.#ctx;
    // `with=station_tasks`: the stream also says when the group's stations changed their Tasks (station-tasks.ts).
    const path = `${route`/v1/comma/groups/${workspace.group_id}/conversations/events`}?with=station_tasks`;
    let lastVersion: string | undefined;
    let backoff = 0;
    const once = Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const body = yield* ctx.api.stream(account, path);
        backoff = 0;
        yield* readEvents(body, (value) =>
          Effect.gen({ self: this }, function* () {
            const event = taskListEventSchema.safeParse(value);
            if (!event.success)
              return yield* Effect.fail(
                new CoreError("bad_response", "an event outside the list's contract")
              );
            if (event.data.group_id !== workspace.group_id)
              return yield* Effect.fail(
                new CoreError("bad_response", "an event of another group")
              );
            if (event.data.type === "station_tasks_invalidated") {
              this.onStationTasksChanged?.(workspace.id);
              return;
            }
            if (
              event.data.type !== "conversation_list_resync_required" &&
              event.data.version === lastVersion
            )
              return;
            lastVersion = event.data.version;
            // A version is only a hint: a read that does not settle starts the stream again, whose resync replays it.
            const read = yield* Effect.result(
              this.#refresh(account, workspace.id, Priority.shown, [])
            );
            if (Result.isFailure(read)) return yield* Effect.fail(read.failure);
          })
        );
      })
    );
    this.#live.run(
      topic,
      Effect.gen(function* () {
        for (;;) {
          const ended = yield* Effect.result(once);
          if (account.closed) return;
          // An end the server chose waits too: a stream that keeps ending at once must not spin.
          if (Result.isFailure(ended)) lastVersion = undefined;
          yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
          backoff++;
        }
      }).pipe(Effect.ensuring(Effect.sync(() => void delete state.streaming)))
    );
  }

  #value(topic: Topic): ProductInboxListResult | null {
    const account = this.#ctx.session.current();
    if (!account)
      return {
        items: [],
        source: "unavailable",
        errorCode: "session_product_lease_unavailable",
      };
    const workspaces = this.#known(account);
    const workspace = this.#workspaceOf(account, topic.workspace);
    const state = this.#state(workspace);
    const kept = workspace ? account.doc<Kept>(doc(workspace))?.value : undefined;
    const base = {
      ...(workspace ? { activeWorkspaceId: workspace } : {}),
      ...(workspaces.length > 0 ? { workspaces } : {}),
    };
    if (!kept) {
      if (state.error)
        return { ...base, errorCode: state.error, items: [], source: "error" };
      if (state.live)
        return {
          ...base,
          items: [],
          lastSyncedAt: this.#ctx.now(),
          source: "live-sync",
        };
      // Nothing kept and nothing read yet: still loading. An empty list here
      // would show "no Tasks" and then animate every card in as new.
      return null;
    }
    const last = kept.pages.at(-1);
    return {
      ...base,
      ...(state.error ? { errorCode: state.error } : {}),
      ...(last?.hasMore === undefined ? {} : { hasMore: last.hasMore }),
      items: this.#staged(kept.pages.flatMap((page) => page.items)).map(withStatus),
      lastSyncedAt: kept.readAt,
      ...(last?.hasMore && last.nextCursor ? { nextCursor: last.nextCursor } : {}),
      source: state.live && !state.error ? "live-sync" : "cache",
    };
  }

  /** The list with the changes people made that the server does not show yet; a stage it shows (or outran) ends. */
  #staged(items: ProductInboxItem[]): ProductInboxItem[] {
    if (this.#stages.size === 0) return items;
    const byTask = new Map(
      items.map((item) => [`${item.groupId}\n${item.conversationId}`, item])
    );
    const shown = new Map<string, string>();
    for (const [id, stage] of this.#stages) {
      const item = byTask.get(`${stage.groupId}\n${stage.conversationId}`);
      if (!item) {
        if (stage.settled) this.#stages.delete(id);
        continue;
      }
      if (
        item.status === stage.status ||
        (stage.version !== undefined && (item.archiveVersion ?? 0) > stage.version)
      ) {
        this.#stages.delete(id);
        continue;
      }
      shown.set(item.id, stage.status);
    }
    return shown.size === 0
      ? items
      : items.map((item) =>
          shown.has(item.id) ? { ...item, status: shown.get(item.id)! } : item
        );
  }
}
