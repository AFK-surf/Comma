// The Tasks a workspace's stations host (chats on each station's own page), as the stations last reported them to
// Comma (`GET /v1/comma/groups/:group/station-tasks`, Salix's Task index). Comma keeps no Message of them: this is a
// list. The device keeps the last list read (`station_task`), so it shows at once, offline too; while shown the core
// reads it again, and again whenever the workspace's task stream (tasks.ts, opened with `?with=station_tasks`) says the
// stations changed their Tasks.
//
// Bounds: one read per shown workspace in flight, sent again only when the stream says the Tasks changed (conditional:
// the answer is 304 when nothing did); a failed read is tried again after 1, 2, 4… up to 15 s while shown. The server
// answers at most 500 Tasks.
import { CoreError, topicKey, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Result } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { stationTasksSchema } from "./comma/schemas.ts";
import type { StationTask, StationTasksValue } from "./contract.ts";
import { Live, type Ctx } from "./ctx.ts";
import type { Stations } from "./stations/index.ts";
import type { Workspaces } from "./workspaces.ts";

const TIMEOUT_MS = 5_000;
const RETRY_MS = [1_000, 2_000, 4_000, 8_000, 15_000];

type Read = { live: boolean; failed: boolean; etag?: string };

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
    const account = this.#ctx.session.current();
    if (!account) return;
    account.patchStationTask(station, thread, { labels });
    this.#shownChanged();
  }

  /** The workspace's stations changed their Tasks (its task stream said so): a shown list is read again. */
  changed(workspace: string): void {
    const account = this.#ctx.session.current();
    if (!account) return;
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (
        topic.topic !== "stationTasks" ||
        this.#workspaceOf(account, topic.workspace) !== workspace
      )
        continue;
      this.#live.run(topic, Effect.ignore(this.#read(account, workspace, true)));
    }
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
      const workspace = this.#workspaceOf(account.success, topic.workspace);
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
      if (topic.topic !== "stationTasks") continue;
      const workspace = this.#workspaceOf(account, topic.workspace);
      if (
        workspace &&
        !this.#reads.get(workspace)?.live &&
        !this.#reading.has(workspace) &&
        !this.#keeping.has(topicKey(topic))
      )
        this.#live.run(topic, this.#keep(topic));
    }
  }

  /** Every shown list computes its value again. */
  #shownChanged(): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "stationTasks") this.#ctx.kernel.store.invalidate(topic);
  }

  #groupOf(account: Account, workspace: string): string | undefined {
    return this.#workspaces.list(account)?.find((w) => w.id === workspace)?.group_id;
  }

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
    const named = new Map(this.#stations.named(workspace).map((s) => [s.id, s]));
    return {
      state: read?.live ? "ready" : "kept",
      ...(read?.failed ? { failed: true } : {}),
      tasks: account
        .stationTasks<Omit<StationTask, "machine">>(workspace)
        .map((task) => {
          const machine = named.get(task.station);
          return {
            ...task,
            // A Task kept before labels has none.
            labels: task.labels ?? [],
            machine: machine ? { name: machine.name, online: machine.online } : null,
          };
        }),
    };
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
    id: `station:${t.station_id}:${t.thread}`,
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
