// The Tasks a workspace's stations host (chats on each station's own page), as the stations last reported them to
// Comma (`GET /v1/comma/groups/:group/station-tasks`, Salix's Task index). Comma keeps no Message of them: this is a
// list. The device keeps the last list read (`station_task`), so it shows at once, offline too; while shown the core
// reads it again, and again whenever the workspace's task stream (tasks.ts, opened with `?with=station_tasks`) says the
// stations changed their Tasks. A task list asked with `hosted` (tasks.ts) takes them in as its items, and is read for
// as this topic is.
//
// Bounds: one read per shown workspace in flight, sent again only when the stream says the Tasks changed (conditional:
// the answer is 304 when nothing did); a failed read is tried again after 1, 2, 4… up to 15 s while shown. The server
// answers at most 500 Tasks.
import { CoreError, topicKey, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { stationTasksSchema } from "./comma/schemas.ts";
import type {
  ProductInboxItem,
  StationTask,
  StationTasksValue,
  TaskAction,
} from "./contract.ts";
import { Live, type Ctx } from "./ctx.ts";
import type { Stations } from "./stations/index.ts";
import type { Workspaces } from "./workspaces.ts";

const TIMEOUT_MS = 5_000;

/** A station-hosted Task's id, as its list item and its conversation have it: `station:<station>:<thread>`. */
export const hostedId = (station: string, thread: string | number) =>
  `station:${station}:${thread}`;

/** The chat on a station a station-hosted Task's id names; null for any other id. */
export function hostedChat(id: string): { station: string; thread: number } | null {
  const named = /^station:([^:]+):([0-9]+)$/.exec(id);
  const thread = named ? Number(named[2]) : NaN;
  return named && Number.isSafeInteger(thread) && thread > 0
    ? { station: named[1]!, thread }
    : null;
}

/**
 * A station's Task status in a Task's words, as every client reads a Task's: at work `active`; for its person, done and
 * waiting for its review (`ready_for_review`) once its station's chat says it asks nothing (`asking` false: no card,
 * decision or need waits), else waiting on them (`escalated`); then `completed`, `cancelled`, `archived`.
 */
export function taskStatusOf(status: string, asking: boolean | null = null): string {
  switch (status) {
    case "needs_review":
      return asking === false ? "ready_for_review" : "escalated";
    case "done":
      return "completed";
    case "cancelled":
    case "archived":
      return status;
    default:
      return "active";
  }
}

/**
 * What a station-hosted Task cannot take from here, as its list item and its page say (`ProductInboxItem.unsupported`,
 * `ConversationProjection.unsupported`): it runs on stations alone (its own, or another computer's), not inside
 * Comma.
 */
export const HOSTED_UNSUPPORTED: TaskAction[] = ["comma"];
const RETRY_MS = [1_000, 2_000, 4_000, 8_000, 15_000];

type Read = { live: boolean; failed: boolean; etag?: string };

/** A topic that shows a workspace's station-hosted Tasks: this one, a task list asked with them, or one's page. */
const shows = (topic: Topic) =>
  topic.topic === "stationTasks" ||
  (topic.topic === "tasks" && topic.hosted === "1") ||
  topic.topic === "archivedTasks" ||
  (topic.topic === "chatView" && hostedChat(String(topic.conversation)) !== null);

export class StationTasks {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #stations: Stations;
  readonly #live: Live;
  /** This run's reads, by workspace. */
  readonly #reads = new Map<string, Read>();
  /** Workspaces whose Tasks changed while a read was under way: read again after it. */
  readonly #again = new Set<string>();
  readonly #reading = new Set<string>();
  /** The shown lists whose first read is under way (`#keep`), by topic key. */
  readonly #keeping = new Set<string>();
  #accountKey: string | null = null;
  /** Told whenever what is shown of the station-hosted Tasks changed. */
  readonly #listeners: (() => void)[] = [];

  constructor(ctx: Ctx, workspaces: Workspaces, stations: Stations) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#stations = stations;
    this.#live = new Live(ctx.runner);
    ctx.kernel.source("stationTasks", {
      start: (topic) => this.#live.run(topic, this.#keep(topic)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    // A list shown before the workspaces were known is read once they are.
    workspaces.onChange(() => this.#keepShown());
    // Which machine hosts each Task, and whether this device reaches it, moves with the stations.
    stations.onChange(() => this.#shownChanged());
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account: nothing read for the one before is shown. The first one signed in finds the shown lists
      // waiting for it (or reading already).
      const switched = this.#accountKey !== null;
      this.#accountKey = key;
      if (switched) {
        this.#reads.clear();
        this.#again.clear();
        this.#live.stopAll();
      }
      this.#keepShown();
    });
  }

  /**
   * A Task's labels as its station answered a change of them: the device's copy shows them now, before the station's
   * next report reaches Comma.
   */
  keepLabels(station: string, thread: string, labels: string[]): void {
    this.#patch(station, thread, { labels });
  }

  /** A Task's name as its station answered a change of it. */
  keepTitle(station: string, thread: string, title: string): void {
    this.#patch(station, thread, { title });
  }

  /**
   * The runtime (unchanged when absent) and model a person switched a Task to (null: the runtime's default there),
   * until its station says it.
   */
  keepRun(
    station: string,
    thread: string,
    run: { runtime?: string; model: string | null }
  ): void {
    this.#patch(
      station,
      thread,
      run.runtime === undefined
        ? { model: run.model }
        : { runtime: run.runtime, model: run.model }
    );
  }

  /** A Task's status as its station answered a change of it. */
  keepStatus(station: string, thread: string, status: string): void {
    this.#patch(station, thread, { status });
  }

  #patch(station: string, thread: string, change: Partial<StationTask>): void {
    const account = this.#ctx.session.current();
    if (!account) return;
    account.patchStationTask(station, thread, change);
    this.#shownChanged();
  }

  /** A station-hosted Task as the device keeps it, with what this device knows of its machine; null when not kept. */
  task(account: Account, workspace: string, id: string): StationTask | null {
    return this.#tasks(account, workspace).find((task) => task.id === id) ?? null;
  }

  /**
   * Its status in a Task's words (`taskStatusOf`), and while it waits for its review the version an acceptance names
   * (its last activity: its station takes any).
   */
  shownStatus(task: StationTask): { status: string; reviewVersion?: number } {
    const status = taskStatusOf(
      task.status,
      this.asking?.(task.station, task.thread) ?? null
    );
    return status === "ready_for_review"
      ? { status, reviewVersion: task.lastActivityAt ?? task.createdAt ?? 1 }
      : { status };
  }

  /** What its stations' chats ask changed (`asking`): the lists and pages that show their Tasks compute again. */
  askingChanged(): void {
    this.#shownChanged();
  }

  /** A workspace's archived station-hosted Tasks, as the device keeps them. */
  archived(account: Account, workspace: string): StationTask[] {
    return this.#tasks(account, workspace).filter((task) => task.status === "archived");
  }

  /** The workspace's stations changed their Tasks (its task stream said so): a shown list is read again. */
  changed(workspace: string): void {
    const account = this.#ctx.session.current();
    if (!account) return;
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (!shows(topic) || this.#workspaceIn(account, topic) !== workspace) continue;
      this.#live.run(topic, Effect.ignore(this.#read(account, workspace, true)));
    }
  }

  /** Keeps a task list's station-hosted Tasks current while it is shown (`hosted`): read, as this topic is. */
  keep(topic: Topic): Effect.Effect<void> {
    return this.#keep(topic);
  }

  /** A task list that showed them is no longer shown: what was reading for it stops. */
  stop(topic: Topic): void {
    this.#live.stop(topic);
  }

  /** A workspace's station-hosted Tasks as a task list's items (tasks.ts, `hosted`); the archived ones are not. */
  items(account: Account, workspace: string): ProductInboxItem[] {
    const known = this.#workspaces.list(account)?.find((w) => w.id === workspace);
    if (!known) return [];
    return this.#tasks(account, workspace)
      .filter((task) => task.status !== "archived")
      .map((task) => ({
        id: task.id,
        source: "station.chat",
        groupId: known.group_id,
        workspaceId: workspace,
        workspaceName: known.name,
        // A station's Task has no Salix conversation: its id stands in, and the core opens it on its station.
        conversationId: task.id,
        kind: "agent_task",
        labels: task.labels,
        title: task.title ?? "",
        ...this.shownStatus(task),
        updatedAt: task.lastActivityAt ?? task.createdAt ?? 0,
        // The version its status is set at, as a Salix Task's: its station takes any.
        archiveVersion: task.lastActivityAt ?? task.createdAt ?? 1,
        unsupported: HOSTED_UNSUPPORTED,
        host: {
          station: task.station,
          thread: task.thread,
          machine: task.machine,
          model: task.model,
          runtime: task.runtime,
        },
      }));
  }

  #keep(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = topicKey(topic);
    return Effect.gen({ self: this }, function* () {
      this.#keeping.add(key);
      const account = yield* Effect.result(ctx.session.account());
      if (Result.isFailure(account)) return;
      // The workspaces are read first when none is known (a list shown before any other view of them).
      if (!this.#workspaces.list(account.success))
        yield* this.#workspaces.refresh().pipe(Effect.ignore);
      const workspace = this.#workspaceIn(account.success, topic);
      // Not known yet: read once the workspaces are (above).
      if (!this.#groupOf(account.success, workspace)) return;
      for (let attempt = 0; ; attempt++) {
        const read = yield* Effect.result(this.#read(account.success, workspace));
        if (Result.isSuccess(read) || account.success.closed) return;
        yield* Effect.sleep(RETRY_MS[Math.min(attempt, RETRY_MS.length - 1)]!);
      }
    }).pipe(Effect.ensuring(Effect.sync(() => void this.#keeping.delete(key))));
  }

  /** Reads the list; `changed`: it changed since a read under way began, which is read again after it. */
  #read(
    account: Account,
    workspace: string,
    changed = false
  ): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      if (this.#reading.has(workspace)) {
        if (changed) this.#again.add(workspace);
        return;
      }
      const group = this.#groupOf(account, workspace);
      if (!group)
        return yield* Effect.fail(new CoreError("not_found", "no such workspace"));
      const read = this.#readOf(workspace);
      this.#reading.add(workspace);
      const answer = yield* ctx.api
        .get(
          account,
          route`/v1/comma/groups/${group}/station-tasks`,
          stationTasksSchema,
          read.etag,
          TIMEOUT_MS
        )
        .pipe(
          Effect.tapError(() =>
            Effect.sync(() => {
              read.failed = true;
              this.#shownChanged();
            })
          ),
          Effect.ensuring(Effect.sync(() => void this.#reading.delete(workspace)))
        );
      if (!answer.notModified) {
        account.replaceStationTasks(
          workspace,
          answer.value.tasks.map((t) => ({
            station: t.station_id,
            thread: t.thread,
            status: t.status,
            lastActivityAt: t.last_activity_at,
            rev: t.rev,
            value: fromRow(t),
          }))
        );
        if (answer.etag) read.etag = answer.etag;
        else delete read.etag;
      }
      read.live = true;
      read.failed = false;
      this.#shownChanged();
      if (this.#again.delete(workspace)) yield* this.#read(account, workspace, true);
    });
  }

  #readOf(workspace: string): Read {
    let read = this.#reads.get(workspace);
    if (!read) {
      read = { live: false, failed: false };
      this.#reads.set(workspace, read);
    }
    return read;
  }

  /** Every shown list shows again, and one not read yet, nor being read, is read. */
  #keepShown(): void {
    this.#shownChanged();
    const account = this.#ctx.session.current();
    if (!account) return;
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (!shows(topic)) continue;
      const workspace = this.#workspaceIn(account, topic);
      if (
        workspace &&
        !this.#reads.get(workspace)?.live &&
        !this.#reading.has(workspace) &&
        !this.#keeping.has(topicKey(topic))
      )
        this.#live.run(topic, this.#keep(topic));
    }
  }

  /** Told whenever what is shown of the station-hosted Tasks changed (a read, a change made here). */
  onChange(listener: () => void): void {
    this.#listeners.push(listener);
  }

  /** Every shown list computes its value again. */
  #shownChanged(): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (shows(topic)) this.#ctx.kernel.store.invalidate(topic);
    for (const listener of this.#listeners) listener();
  }

  /** The Group of workspace `workspace`, read with the workspaces when this device lists none yet. */
  group(workspace: string): Effect.Effect<string, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
      if (!this.#workspaces.list(account))
        yield* this.#workspaces.refresh().pipe(Effect.ignore);
      const group = this.#groupOf(account, workspace);
      if (!group)
        return yield* Effect.fail(new CoreError("not_found", "No such workspace."));
      return group;
    });
  }

  #groupOf(account: Account, workspace: string): string | undefined {
    return this.#workspaces.list(account)?.find((w) => w.id === workspace)?.group_id;
  }

  /** A topic's workspace: a task list's as the list means it (`tasksWorkspace`: it can follow the focus), else this one's. */
  #workspaceIn(account: Account, topic: Topic): string {
    return (topic.topic === "tasks" || topic.topic === "archivedTasks") &&
      this.tasksWorkspace
      ? this.tasksWorkspace(account, topic.workspace)
      : this.#workspaceOf(account, topic.workspace);
  }

  /**
   * Whether a station's chat asks its person something now (a card, a decision or a need waits), as its station's chats
   * were last read; null when they were never read (stations/activity.ts).
   */
  asking: ((station: string, thread: string) => boolean | null) | undefined;

  /** The workspace a task list means (tasks.ts `workspace`): its own, else the one in focus, else the first known. */
  tasksWorkspace: ((account: Account, wanted: unknown) => string) | undefined;

  /** A topic's workspace: its own, else the first known; "" while none is known. */
  #workspaceOf(account: Account, wanted: unknown): string {
    const known = this.#workspaces.list(account) ?? [];
    if (typeof wanted === "string" && wanted) return wanted;
    return known[0]?.id ?? "";
  }

  #value(topic: Topic): StationTasksValue {
    const account = this.#ctx.session.current();
    const workspace = account ? this.#workspaceOf(account, topic.workspace) : "";
    if (!account || !workspace) return { state: "unavailable", tasks: [] };
    const read = this.#reads.get(workspace);
    return {
      state: read?.live ? "ready" : "kept",
      ...(read?.failed ? { failed: true } : {}),
      tasks: this.#tasks(account, workspace),
    };
  }

  /** A workspace's station-hosted Tasks as kept, each with what this device knows of its machine. */
  #tasks(account: Account, workspace: string): StationTask[] {
    const named = new Map(this.#stations.named(workspace).map((s) => [s.id, s]));
    return account.stationTasks<Omit<StationTask, "machine">>(workspace).map((task) => {
      const machine = named.get(task.station);
      return {
        ...task,
        // A Task kept before labels has none.
        labels: task.labels ?? [],
        machine: machine ? { name: machine.name, online: machine.online } : null,
      };
    });
  }
}

function fromRow(t: {
  station_id: string;
  device_id: string | null;
  thread: string;
  title: string | null;
  status: string;
  created_by: string | null;
  created_at: number | null;
  last_activity_at: number | null;
  runtime: string | null;
  model: string | null;
  labels: string[];
}): Omit<StationTask, "machine"> {
  return {
    id: hostedId(t.station_id, t.thread),
    station: t.station_id,
    device: t.device_id,
    thread: t.thread,
    title: t.title,
    status: t.status,
    createdBy: t.created_by,
    createdAt: t.created_at,
    lastActivityAt: t.last_activity_at,
    runtime: t.runtime,
    model: t.model,
    labels: t.labels,
  };
}
