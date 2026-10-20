import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type {
  ArchivedTasksValue,
  ProductInboxListResult,
  TaskSummariesValue,
} from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const list = "/v1/comma/groups/g/conversations";
const events = "/v1/comma/groups/g/conversations/events";
const archive = "/v1/comma/groups/g/conversations/t1/archive";
const unarchive = "/v1/comma/groups/g/conversations/t1/unarchive";

const task = (id: string, extra: Record<string, unknown> = {}) => ({
  group_id: "g",
  id,
  kind: "agent_task",
  status: "completed",
  title: `Task ${id}`,
  updated_at: 1,
  archive_availability: { allowed: true, reason: null },
  ...extra,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", list, { data: [task("t1")] });
  host.api.onStream(events);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as T;
  };
  core.observeSession(signedIn());
  const call = (action: "archive" | "unarchive", version = 1) =>
    client.call("tasks.archive", { group: "g", conversation: "t1", action, version });
  return { host, core, client, time: host.time!, api: host.api, watch, call };
}

const statusOf = (value: ProductInboxListResult | null | undefined) =>
  value?.items.find((item) => item.conversationId === "t1")?.status;

describe("archiving a Task", () => {
  it("takes it off every list before the server answers, and keeps it off once it does", async () => {
    const t = setup();
    const tasks = t.watch<ProductInboxListResult>({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    expect(statusOf(tasks())).toBe("completed");
    t.api.on("POST", archive, task("t1", { status: "archived", updated_at: 2 }));
    const release = t.api.hold("POST", archive);
    let settled = false;
    void t.call("archive").then(() => (settled = true));
    await t.time.pass(100);
    expect(statusOf(tasks())).toBe("archived");
    expect(settled).toBe(false);
    // The list still says completed when it reads the Task again; the server's answer has not come.
    t.api.on("GET", "/v1/comma/groups/g/task-summaries", {
      data: [task("t1", { status: "archived", updated_at: 2 })],
    });
    release();
    await t.time.pass(100);
    expect(settled).toBe(true);
    expect(statusOf(tasks())).toBe("archived");
    expect(t.api.seen("POST", archive)[0]!.body).toEqual({ expected_updated_at: 1 });
    // The list read the Task again, exactly.
    expect(t.api.seen("GET", "/v1/comma/groups/g/task-summaries")[0]!.path).toContain(
      "ids=t1"
    );
  });

  it("brings it back when the server refuses, and reads it again on a conflict", async () => {
    const t = setup();
    const tasks = t.watch<ProductInboxListResult>({ topic: "tasks", workspace: "wsp" });
    t.api.on("GET", "/v1/comma/groups/g/task-summaries", { data: [task("t1")] });
    await t.time.pass(100);
    t.api.on("POST", archive, json(409, { error: "conversation_changed" }));
    const release = t.api.hold("POST", archive);
    const done = t.call("archive").then(
      () => null,
      (error: { code: string }) => error.code
    );
    await t.time.pass(100);
    expect(statusOf(tasks())).toBe("archived");
    release();
    await t.time.pass(100);
    expect(await done).toBe("conversation_changed");
    expect(statusOf(tasks())).toBe("completed");
    // The list read the Task again, exactly.
    expect(t.api.seen("GET", "/v1/comma/groups/g/task-summaries")).toHaveLength(1);
  });

  it("sends one request while one is under way for the same Task", async () => {
    const t = setup();
    t.api.on("POST", archive, task("t1", { status: "archived", updated_at: 2 }));
    const release = t.api.hold("POST", archive);
    void t.call("archive");
    await t.time.pass(100);
    expect(await t.call("archive")).toBe(false);
    release();
    await t.time.pass(100);
    expect(t.api.seen("POST", archive)).toHaveLength(1);
  });

  it("keeps the server's answer for the Tasks shown from the summary cache", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/g/task-summaries", { data: [] });
    const shown = t.watch<TaskSummariesValue>({
      topic: "taskSummaries",
      group: "g",
      ids: "t9",
      peek: "1",
    });
    t.api.on(
      "POST",
      "/v1/comma/groups/g/conversations/t9/archive",
      task("t9", { status: "archived", updated_at: 7 })
    );
    await t.client.call("tasks.archive", {
      group: "g",
      conversation: "t9",
      action: "archive",
      version: 6,
    });
    await t.time.pass(100);
    expect(shown().summaries).toEqual([
      expect.objectContaining({ id: "t9", status: "archived", updated_at: 7 }),
    ]);
  });
});

describe("Settings › Archived tasks", () => {
  it("reads 50 at a time, the next page when asked, and drops a Task unarchived there", async () => {
    const t = setup();
    t.api.on("GET", list, (r) =>
      json(
        200,
        r.path.includes("archive=only")
          ? r.path.includes("cursor=p2")
            ? { data: [task("t2", { status: "archived" })], has_more: false }
            : {
                data: [task("t1", { status: "archived" })],
                has_more: true,
                next_cursor: "p2",
              }
          : { data: [] }
      )
    );
    const shown = t.watch<ArchivedTasksValue>({ topic: "archivedTasks" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      workspace: { id: "wsp", name: "Work" },
      tasks: [{ id: "t1" }],
      hasMore: true,
      loading: false,
      error: null,
    });
    const first = t.api.seen("GET", list).find((r) => r.path.includes("archive=only"))!;
    expect(first.path).toContain("limit=50");
    await t.client.call("archivedTasks.more", {});
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      tasks: [{ id: "t1" }, { id: "t2" }],
      hasMore: false,
    });

    t.api.on("POST", unarchive, task("t1", { updated_at: 3 }));
    await t.call("unarchive", 2);
    await t.time.pass(100);
    expect(shown().tasks.map((x) => x.id)).toEqual(["t2"]);
  });

  it("says a failed read failed and reads again when asked", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", list, (r) =>
      r.path.includes("archive=only") && !up ? offline() : json(200, { data: [] })
    );
    const shown = t.watch<ArchivedTasksValue>({ topic: "archivedTasks" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ loading: false, error: "network unreachable" });
    up = true;
    await t.client.call("archivedTasks.refresh", {});
    await t.time.pass(100);
    expect(shown()).toMatchObject({ loading: false, error: null, tasks: [] });
  });
});

describe("a member's other changes to a Task", () => {
  it("renames, accepts and stops a Task, each then read again on the list in focus", async () => {
    const t = setup();
    const tasks = t.watch<ProductInboxListResult>({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    t.api.on(
      "PATCH",
      "/v1/comma/groups/g/conversations/t1",
      task("t1", { title: "New", updated_at: 2 })
    );
    t.api.on(
      "POST",
      "/v1/comma/groups/g/conversations/t1/accept",
      task("t1", { updated_at: 3 })
    );
    t.api.on(
      "POST",
      "/v1/comma/groups/g/conversations/t1/cancel",
      task("t1", { status: "cancelled", updated_at: 4 })
    );
    t.api.on("GET", "/v1/comma/groups/g/task-summaries", {
      data: [task("t1", { title: "New", status: "cancelled", updated_at: 4 })],
    });
    const ask = async (name: string, params: Record<string, unknown>) => {
      const done = t.client.call(name, { group: "g", conversation: "t1", ...params });
      await t.time.pass(100);
      return done;
    };
    await ask("tasks.rename", { title: "  New  " });
    expect(t.api.seen("PATCH", "/v1/comma/groups/g/conversations/t1")[0]!.body).toEqual(
      { title: "New" }
    );
    await ask("tasks.accept", { reviewVersion: 7 });
    expect(
      t.api.seen("POST", "/v1/comma/groups/g/conversations/t1/accept")[0]!.body
    ).toEqual({
      review_version: 7,
    });
    await ask("tasks.cancel", {});
    expect(
      t.api.seen("POST", "/v1/comma/groups/g/conversations/t1/cancel")
    ).toHaveLength(1);
    expect(tasks()?.items.find((item) => item.conversationId === "t1")).toMatchObject({
      title: "New",
      status: "cancelled",
    });
  });

  it("shows a pin at once and the server's pins once it answered", async () => {
    const t = setup();
    let pins = [] as { conversation: { id: string; group_id: string } }[];
    t.api.on("GET", "/v1/comma/groups/g/conversation-pins", () =>
      json(200, { data: pins })
    );
    const shown = t.watch<{ status: string; ids: string[] }>({
      topic: "taskPins",
      group: "g",
    });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "ready", ids: [] });
    const release = t.api.hold("PUT", "/v1/comma/groups/g/conversations/t1/pin");
    t.api.on("PUT", "/v1/comma/groups/g/conversations/t1/pin", () => {
      pins = [{ conversation: { id: "t1", group_id: "g" } }];
      return json(200, { conversation: { id: "t1", group_id: "g" } });
    });
    const pinned = t.client.call("tasks.pin", {
      group: "g",
      conversation: "t1",
      pinned: true,
    });
    await t.time.pass(100);
    expect(shown().ids).toEqual(["t1"]);
    release();
    await t.time.pass(100);
    await pinned;
    expect(shown()).toEqual({ status: "ready", ids: ["t1"] });
  });
});

describe("Archived tasks, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.watch({ topic: "archivedTasks" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) =>
        input.kind === "response" && input.request.path.includes("archive=only")
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll("Task t1", "Renamed")));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
