import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskSummariesValue } from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const list = "/v1/comma/groups/g/conversations";
const events = "/v1/comma/groups/g/conversations/events";
const summaries = "/v1/comma/groups/g/task-summaries";

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
const idsOf = (request: SeenRequest) =>
  new URL(`https://x${request.path}`).searchParams.get("ids")!.split(",");
/** Answers each Task asked for with `extra`. */
const answering =
  (extra: Record<string, unknown> = {}) =>
  (request: SeenRequest) =>
    json(200, { data: idsOf(request).map((id) => task(id, extra)) });

/** No answer: the network is down. */
const unanswered = () => offline();

function setup(listed: unknown[] = []) {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", list, { data: listed });
  host.api.onStream(events);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    stops.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      )
    );
    return () => values.get(key) as TaskSummariesValue | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, unwatch };
}

const shown = (ids: string[], extra: Record<string, string> = {}) => ({
  topic: "taskSummaries",
  group: "g",
  ids: ids.join(","),
  ...extra,
});

describe("the Tasks a surface refers to", () => {
  it("asks for them once each, at most 50 a request, one request at a time", async () => {
    const t = setup();
    t.api.on("GET", summaries, answering());
    const ids = Array.from({ length: 121 }, (_, i) => String(i));
    const release = t.api.hold("GET", summaries);
    const value = t.watch(shown(ids));
    // A second surface showing some of the same Tasks asks for none of them again.
    t.watch(shown(ids.slice(0, 10)));
    await t.time.pass(100);
    expect(t.api.seen("GET", summaries)).toHaveLength(1);
    release();
    await t.time.pass(100);
    expect(t.api.seen("GET", summaries).map((r) => idsOf(r).length)).toEqual([
      50, 50, 21,
    ]);
    expect(value()?.summaries).toHaveLength(121);
    expect(value()?.summaries[120]).toMatchObject({
      id: "120",
      status: "completed",
      status_bucket: "done",
      status_failed: false,
    });
  });

  it("takes the list's facts for a Task it has with a version, and asks for none", async () => {
    const t = setup([task("listed", { updated_at: 5, title: "From the list" })]);
    t.api.on("GET", summaries, answering());
    t.watch({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    const value = t.watch(shown(["listed"]));
    await t.time.pass(100);
    expect(value()?.summaries).toEqual([
      expect.objectContaining({ id: "listed", title: "From the list", updated_at: 5 }),
    ]);
    expect(t.api.seen("GET", summaries)).toHaveLength(0);
  });

  it("carries when a Task's latest run started, from the list or the Task's own answer", async () => {
    const t = setup([
      task("listed", { updated_at: 5, run_started_at: 1_700_000_000_000 }),
    ]);
    t.api.on("GET", summaries, answering({ run_started_at: 1_700_000_500_000 }));
    t.watch({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    const value = t.watch(shown(["listed", "outside"]));
    await t.time.pass(100);
    expect(value()?.summaries.map((summary) => summary.run_started_at)).toEqual([
      1_700_000_000_000, 1_700_000_500_000,
    ]);
  });

  it("carries a Task's Loop as the list has it, from the list or the Task's own answer", async () => {
    const loop = {
      state: "active",
      cadence: { cron: "0 9 * * *", timezone: "Asia/Shanghai" },
      started_at: 1_700_000_000_000,
      wake_count: 3,
      next_run_at: 1_700_086_400_000,
    };
    const t = setup([task("listed", { updated_at: 5, loop })]);
    t.api.on("GET", summaries, (request) =>
      json(200, {
        data: idsOf(request).map((id) =>
          task(
            id,
            id === "one-off"
              ? { schedule: { command: "Summarize the week" } }
              : { loop: { ...loop, state: "ended", reason: "completed" } }
          )
        ),
      })
    );
    t.watch({ topic: "tasks", workspace: "wsp" });
    await t.time.pass(100);
    const value = t.watch(shown(["listed", "outside", "one-off"]));
    await t.time.pass(100);
    const read = {
      state: "active",
      cadence: {
        pattern: { kind: "daily", hour: 9, minute: 0 },
        cron: "0 9 * * *",
        timezone: "Asia/Shanghai",
      },
      startedAt: 1_700_000_000_000,
      wakeCount: 3,
      nextRunAt: 1_700_086_400_000,
    };
    const [listed, outside, oneOff] = value()!.summaries;
    expect(listed?.loop).toEqual(read);
    expect(outside?.loop).toEqual({ ...read, state: "ended", reason: "completed" });
    expect(oneOff?.loop).toBeUndefined();
  });

  it("drops an answer sent before a read of the list, and learns an archive outside its page", async () => {
    const t = setup();
    // Each answer is told apart by its title; the third one says archived.
    let answers = 0;
    t.api.on("GET", summaries, (r) => {
      answers++;
      return answering({
        title: `v${answers}`,
        status: answers < 3 ? "completed" : "archived",
      })(r);
    });
    const value = t.watch(shown(["old"]));
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({ title: "v1" });

    // The second request is held; the list is read meanwhile (its stream said it changed).
    const second = t.api.hold("GET", summaries);
    t.core.taskSummaries.invalidate();
    await t.time.pass(100);
    t.api.open(events)!.event({
      type: "conversation_list_invalidated",
      group_id: "g",
      kind: "agent_task",
      version: "2",
    });
    await t.time.pass(100);
    expect(t.api.seen("GET", list)).toHaveLength(2);
    const third = t.api.hold("GET", summaries);
    second();
    await t.time.pass(100);
    // The answer to the request sent before the read is not taken.
    expect(value()?.summaries[0]).toMatchObject({ title: "v1" });
    third();
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({ title: "v3", status: "archived" });
    expect(answers).toBe(3);
  });

  it("keeps a known archive through failed and older answers, and shows stale facts without archive permission", async () => {
    const t = setup();
    let answer: (r: SeenRequest) => unknown = unanswered;
    t.api.on("GET", summaries, (r) => answer(r) as never);
    t.core.taskSummaries.record(
      task("old", { status: "archived", updated_at: 2 }) as never
    );
    const value = t.watch(shown(["old"]));
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({ status: "archived" });
    // A failed read: known, but not confirmed.
    t.core.taskSummaries.invalidate();
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({ status: "archived" });
    expect(value()?.summaries[0]?.archive_availability).toBeUndefined();
    // An older answer does not undo the archive.
    answer = answering({ updated_at: 1 });
    t.core.taskSummaries.invalidate();
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({ status: "archived" });
    answer = answering({ updated_at: 3 });
    t.core.taskSummaries.invalidate();
    await t.time.pass(100);
    expect(value()?.summaries[0]).toMatchObject({
      status: "completed",
      archive_availability: { allowed: true, reason: null },
    });
    expect(t.api.seen("GET", summaries)).toHaveLength(3);
  });

  it("knows at most 1,000 Tasks, evicts none and does not ask again for them", async () => {
    const t = setup();
    t.api.on("GET", summaries, answering());
    const value = t.watch(shown(Array.from({ length: 1_200 }, (_, i) => String(i))));
    await t.time.pass(1_000);
    expect(value()?.summaries).toHaveLength(1_000);
    expect(t.api.seen("GET", summaries)).toHaveLength(20);
    t.watch(shown(["0", "1000"]));
    await t.time.pass(100);
    expect(t.api.seen("GET", summaries)).toHaveLength(20);
  });

  it("asks for nothing when a surface only peeks", async () => {
    const t = setup();
    t.api.on("GET", summaries, answering());
    const value = t.watch(shown(["a"], { peek: "1" }));
    await t.time.pass(100);
    expect(value()?.summaries).toEqual([]);
    expect(t.api.seen("GET", summaries)).toHaveLength(0);
  });
});

describe("the Tasks a surface refers to, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", summaries, answering());
    t.watch(shown(["a"]));
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(summaries)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(
      new TextEncoder().encode(body.replaceAll("completed", "running"))
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
