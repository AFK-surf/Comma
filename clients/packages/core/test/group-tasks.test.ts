import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { GroupTaskValue, GroupTasksValue } from "../src/contract.ts";
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

const LIST = "/v1/comma/groups/grp_1/conversations";
const PREVIEW = "/v1/comma/groups/grp_1/conversations/cnv_1/preview";

const row = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  group_id: "grp_1",
  kind: "agent_task",
  title: `Task ${id}`,
  status: "active",
  updated_at: 1790100000,
  ...extra,
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    stops.set(
      k,
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, stops };
}

const list = (read = "0") => ({ topic: "groupTasks", group: "grp_1", read });

describe("the Task panel's list of a Group's Tasks", () => {
  it("reads pages of 20, shows only agent Tasks, and appends the next page once", async () => {
    const t = setup();
    t.api.on("GET", LIST, (request) =>
      json(
        200,
        request.path.includes("cursor=")
          ? { data: [row("cnv_3")], has_more: false }
          : {
              data: [
                row("cnv_1"),
                row("cnv_chat", { kind: "user_chat" }),
                row("cnv_2"),
              ],
              has_more: true,
              next_cursor: "next page",
            }
      )
    );
    const shown = t.watch<GroupTasksValue>(list());
    await t.time.pass(100);
    expect(t.api.requests.map((r) => r.path)).toEqual([`${LIST}?limit=20`]);
    expect(shown()).toEqual({
      status: "ready",
      tasks: [
        {
          id: "cnv_1",
          title: "Task cnv_1",
          status: "active",
          updatedAt: 1790100000,
          activityStatus: "idle",
        },
        expect.objectContaining({ id: "cnv_2" }),
      ],
      more: "idle",
    });

    const release = t.api.hold("GET", LIST);
    await t.client.call("groupTasks.more", { group: "grp_1", read: "0" });
    // Asked again while the page is read: still one read.
    await t.client.call("groupTasks.more", { group: "grp_1", read: "0" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "ready", more: "loading" });
    release();
    await t.time.pass(100);
    expect(t.api.requests.map((r) => r.path)).toEqual([
      `${LIST}?limit=20`,
      `${LIST}?cursor=next%20page&limit=20`,
    ]);
    expect(shown()).toMatchObject({ status: "ready", more: "none" });
    expect(
      (shown() as { tasks: { id: string }[] }).tasks.map((task) => task.id)
    ).toEqual(["cnv_1", "cnv_2", "cnv_3"]);
  });

  it("keeps the list when a next page fails, and reads it again on request", async () => {
    const t = setup();
    t.api.on("GET", LIST, {
      data: [row("cnv_1")],
      has_more: true,
      next_cursor: "c2",
    });
    const shown = t.watch<GroupTasksValue>(list());
    await t.time.pass(100);
    t.api.on("GET", LIST, json(503, { error: "unavailable" }));
    await t.client.call("groupTasks.more", { group: "grp_1", read: "0" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      more: "failed",
      tasks: [{ id: "cnv_1" }],
    });
    t.api.on("GET", LIST, { data: [row("cnv_2")], has_more: false });
    await t.client.call("groupTasks.more", { group: "grp_1", read: "0" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      more: "none",
      tasks: [{ id: "cnv_1" }, { id: "cnv_2" }],
    });
  });

  it("fails without content when the first page cannot be read; a new read asks again", async () => {
    const t = setup();
    t.api.on("GET", LIST, offline());
    const failed = t.watch<GroupTasksValue>(list("0"));
    await t.time.pass(100);
    expect(failed()).toEqual({ status: "failed" });
    t.api.on("GET", LIST, { data: [row("cnv_1")], has_more: false });
    const again = t.watch<GroupTasksValue>(list("1"));
    await t.time.pass(100);
    expect(again()).toMatchObject({
      status: "ready",
      tasks: [{ id: "cnv_1" }],
      more: "none",
    });
  });

  it("gives up a page after 10 s", async () => {
    const t = setup();
    t.api.hold("GET", LIST);
    const shown = t.watch<GroupTasksValue>(list());
    await t.time.pass(9_000, 1_000);
    expect(shown()).toBeNull();
    await t.time.pass(2_000, 1_000);
    expect(shown()).toEqual({ status: "failed" });
  });

  it("replays the same from its record, and differently from a changed answer", async () => {
    const t = setup();
    t.api.on("GET", LIST, (request) =>
      json(
        200,
        request.path.includes("cursor=")
          ? { data: [row("cnv_2")], has_more: false }
          : { data: [row("cnv_1")], has_more: true, next_cursor: "c2" }
      )
    );
    t.watch<GroupTasksValue>(list());
    await t.time.pass(100);
    await t.client.call("groupTasks.more", { group: "grp_1", read: "0" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(LIST)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replace("Task cnv_1", "Renamed")));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});

const task = (read: string) => ({
  topic: "groupTask",
  group: "grp_1",
  conversation: "cnv_1",
  read,
});
const preview = (status: string) => ({
  id: "cnv_1",
  group_id: "grp_1",
  kind: "agent_task",
  title: "Task cnv_1",
  status,
  activity_status: "idle",
  freshness: { state: "fresh" },
  updated_at: 1790100000,
  bound_worker: { participant_id: "ptp_1", name: "Mira" },
});

describe("the Task panel's Task", () => {
  it("reads the preview with its Worker once for each read, and says when it cannot", async () => {
    const t = setup();
    t.api.on("GET", PREVIEW, preview("active"));
    const first = t.watch<GroupTaskValue>(task("1"));
    await t.time.pass(100);
    expect(first()).toEqual({ status: "ready", preview: preview("active") });
    expect(t.api.requests.map((r) => r.path)).toEqual([
      `${PREVIEW}?include_worker=true`,
    ]);

    t.api.on("GET", PREVIEW, preview("ready_for_review"));
    const refreshed = t.watch<GroupTaskValue>(task("2"));
    await t.time.pass(100);
    expect(refreshed()).toEqual({
      status: "ready",
      preview: preview("ready_for_review"),
    });

    t.api.on("GET", PREVIEW, json(404, { error: "not_found" }));
    const gone = t.watch<GroupTaskValue>(task("3"));
    await t.time.pass(100);
    expect(gone()).toEqual({ status: "failed" });
  });

  it("carries a Loop Task's Loop from the preview, with no other read", async () => {
    const t = setup();
    const loop = {
      state: "paused",
      reason: "budget",
      cadence: { every_minutes: 30 },
      started_at: 1790100000,
      wake_count: 2,
    };
    t.api.on("GET", PREVIEW, { ...preview("active"), loop });
    const shown = t.watch<GroupTaskValue>(task("1"));
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      loop: {
        state: "paused",
        reason: "budget",
        cadence: { everyMinutes: 30 },
        wakeCount: 2,
      },
    });
    expect(t.api.requests.map((r) => r.path)).toEqual([
      `${PREVIEW}?include_worker=true`,
    ]);
  });
});
