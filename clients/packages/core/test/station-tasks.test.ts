import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { StationTasksValue } from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const stationTasks = "/v1/comma/groups/g/station-tasks";
const events = "/v1/comma/groups/g/conversations/events";

/** `s` seconds into a day, in Unix milliseconds. */
const at = (s: number) => 1_800_000_000_000 + s * 1_000;

const row = (thread: string, extra: Record<string, unknown> = {}) => ({
  station_id: "a".repeat(64),
  device_id: "dev_mac",
  thread,
  task: `EMBER/${thread}.0`,
  title: `Task ${thread}`,
  status: "in_progress",
  created_by: "ann@x",
  created_at: 1,
  last_activity_at: 10,
  runtime: "codex",
  model: "gpt-5.5",
  labels: ["lbl_ship"],
  rev: 1,
  ...extra,
});

function setup(host = new FakeHost()) {
  let answer: (request: SeenRequest) => unknown = () =>
    json(200, { tasks: [row("7")] });
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", "/v1/comma/groups/g/conversations", json(200, { data: [] }));
  host.api.on("GET", stationTasks, (request: SeenRequest) => answer(request));
  host.api.onStream(events);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    const stop = client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return { value: () => values.get(key) as StationTasksValue | undefined, stop };
  };
  core.observeSession(signedIn());
  return {
    host,
    time: host.time!,
    watch,
    answer: (next: typeof answer) => (answer = next),
    reads: () => host.api.requests.filter((r) => r.path === stationTasks).length,
  };
}

describe("the Tasks a workspace's stations host", () => {
  it("lists them as the stations reported them, and reads them again when the task stream says they changed", async () => {
    const t = setup();
    t.watch({ topic: "tasks", workspace: "" });
    const shown = t.watch({ topic: "stationTasks", workspace: "" });
    await t.time.pass(100);
    expect(shown.value()).toEqual({
      state: "ready",
      tasks: [
        {
          id: `station:${"a".repeat(64)}:7`,
          station: "a".repeat(64),
          device: "dev_mac",
          thread: "7",
          title: "Task 7",
          status: "in_progress",
          createdBy: "ann@x",
          createdAt: 1,
          lastActivityAt: 10,
          runtime: "codex",
          model: "gpt-5.5",
          labels: ["lbl_ship"],
          machine: null,
        },
      ],
    });

    // The task stream asks for station Task changes, and one read follows each.
    const stream = t.host.api.open(events);
    expect(stream).toBeDefined();
    t.answer(() =>
      json(200, {
        tasks: [row("8", { last_activity_at: 20 }), row("7", { status: "done" })],
      })
    );
    stream!.event({ type: "station_tasks_invalidated", group_id: "g" });
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
    expect(shown.value()?.tasks.map((task) => [task.thread, task.status])).toEqual([
      ["8", "in_progress"],
      ["7", "done"],
    ]);
  });

  it("are among a task list's items when it asks for them, each by its last change, read as it is shown", async () => {
    const t = setup();
    t.host.api.on(
      "GET",
      "/v1/comma/groups/g/conversations",
      json(200, {
        data: [
          {
            id: "c2",
            group_id: "g",
            kind: "agent_task",
            status: "active",
            title: "Newer",
            updated_at: at(30),
          },
          {
            id: "c1",
            group_id: "g",
            kind: "agent_task",
            status: "active",
            title: "Older",
            updated_at: at(5),
          },
        ],
      })
    );
    t.answer(() => json(200, { tasks: [row("7", { last_activity_at: at(20) })] }));
    const list = t.watch({ topic: "tasks", workspace: "wsp", hosted: "1" });
    const plain = t.watch({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    type Items = { items: { id: string; source: string; host?: unknown }[] };
    const items = () => (list.value() as unknown as Items).items;
    expect(items().map((item) => item.id)).toEqual([
      "g:c2",
      `station:${"a".repeat(64)}:7`,
      "g:c1",
    ]);
    expect(items()[1]).toMatchObject({
      source: "station.chat",
      conversationId: `station:${"a".repeat(64)}:7`,
      groupId: "g",
      title: "Task 7",
      // In a Task's words: at work.
      status: "active",
      unsupported: ["comma"],
      host: {
        station: "a".repeat(64),
        thread: "7",
        machine: null,
        model: "gpt-5.5",
        runtime: "codex",
      },
    });
    // A list that does not ask has none, and the station-hosted Tasks were read once for the one that did.
    expect((plain.value() as unknown as Items).items.map((item) => item.id)).toEqual([
      "g:c2",
      "g:c1",
    ]);
    expect(t.reads()).toBe(1);

    // The stations changed their Tasks: read again, the list shows it.
    t.answer(() =>
      json(200, { tasks: [row("7", { last_activity_at: at(40), status: "done" })] })
    );
    t.host.api
      .open(events)!
      .event({ type: "station_tasks_invalidated", group_id: "g" });
    await t.time.pass(100);
    expect(items()[0]).toMatchObject({
      id: `station:${"a".repeat(64)}:7`,
      status: "completed",
      statusBucket: "done",
    });
  });

  it("stops reading them for a task list once it is no longer shown", async () => {
    const t = setup();
    let reached = false;
    t.host.api.on("GET", "/v1/comma/workspaces", () =>
      reached ? json(200, { data: [workspace] }) : json(503, { error: "unavailable" })
    );
    t.answer(() => json(503, { error: "unavailable" }));
    // Shown before its workspace is known: read once it is, and again after each failed read while shown.
    const list = t.watch({ topic: "tasks", workspace: "wsp", hosted: "1" });
    await t.time.pass(100);
    reached = true;
    await t.time.pass(30_000);
    expect(t.reads()).toBeGreaterThan(1);
    // Let go once its grace ends (a topic stays live a minute after its last subscriber).
    list.stop();
    await t.time.pass(61_000);
    const stopped = t.reads();
    await t.time.pass(60_000);
    expect(t.reads()).toBe(stopped);
  });

  it("names the machine that hosts each, where this device keeps the workspace's stations", async () => {
    const host = new FakeHost();
    const stations = new FakeStations(() => host.time!.now());
    host.stationMesh = { ...stations.ports, alwaysLinked: true };
    host.api
      .on("GET", "/v1/comma/stations/me", {
        user: { id: "u", email: "ann@x", name: "Ann" },
        workspaces: [{ id: "wsp", name: "Work", role: "owner" }],
        relay_urls: [],
      })
      .on("GET", "/v1/comma/workspaces/wsp/stations", {
        stations: [{ id: "a".repeat(64), name: "Studio", version: "1", online: true }],
      })
      .onStream("/v1/comma/workspaces/wsp/stations/events")
      .on("POST", "/v1/comma/workspaces/wsp/station-credential", () => json(503, {}));
    const t = setup(host);
    const shown = t.watch({ topic: "stationTasks", workspace: "wsp" });
    await t.time.pass(100);
    expect(shown.value()?.tasks[0]?.machine).toEqual({ name: "Studio", online: true });
  });

  it("shows what the device kept before the read, and keeps it when the read fails", async () => {
    const host = new FakeHost();
    const first = setup(host);
    const kept = first.watch({ topic: "stationTasks", workspace: "" });
    await first.time.pass(100);
    expect(kept.value()?.tasks).toHaveLength(1);
    kept.stop();

    first.answer(() => json(503, { error: "unavailable" }));
    const again = first.watch({ topic: "stationTasks", workspace: "wsp" });
    await first.time.pass(100);
    expect(again.value()).toMatchObject({ failed: true, tasks: [{ thread: "7" }] });
  });
});
