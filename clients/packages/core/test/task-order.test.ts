import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskOrderValue } from "../src/contract.ts";
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

const order = "/v1/comma/groups/g/task-order";

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as TaskOrderValue | undefined;
  };
  core.observeSession(signedIn());
  const drop = (bucket: string, visible: string[], group = "g") =>
    client.call("taskOrder.set", { group, bucket, visible });
  return { host, core, client, time: host.time!, api: host.api, watch, drop };
}

/** The sections of a Group none of whose Tasks the list in focus has. */
const none = ["in_progress", "needs_review", "done", "cancelled"].map((bucket) => ({
  bucket,
  ids: [],
}));

/** A Task of the Group as the list reads it. */
function task(id: string, status: string) {
  return {
    group_id: "g",
    id,
    kind: "agent_task",
    status,
    title: id,
    updated_at: 1_700_000_000,
  };
}

describe("a Group's Task-board arrangement", () => {
  it("puts the list's Tasks in board order: new ones first, then the bucket's order", async () => {
    const host = new FakeHost();
    host.api.on("GET", "/v1/comma/workspaces", {
      data: [{ group_id: "g", id: "w", name: "W", status: "ready" }],
    });
    host.api.onStream("/v1/comma/groups/g/conversations/events");
    host.api.on("GET", "/v1/comma/groups/g/conversations", {
      data: [
        task("new", "running"),
        task("a", "running"),
        task("b", "running"),
        task("d", "completed"),
      ],
    });
    host.api.on("GET", order, { orders: { in_progress: ["b", "gone", "a"] } });
    const t = setup(host);
    t.watch({ topic: "tasks", workspace: "w" });
    await t.client.call("tasks.focus", { workspace: "w" });
    const shown = t.watch({ topic: "taskOrder", group: "g" });
    await t.time.pass(100);
    // Every shown status, in the one order every client shows them.
    expect(shown()?.sections).toEqual([
      { bucket: "in_progress", ids: ["new", "b", "a"] },
      { bucket: "needs_review", ids: [] },
      { bucket: "done", ids: ["d"] },
      { bucket: "cancelled", ids: [] },
    ]);

    // A drop is the board's order at once.
    t.api.on("PUT", `${order}/in_progress`, { orders: {} });
    const dropped = t.drop("in_progress", ["a", "new", "b"]);
    await t.time.pass(100);
    await dropped;
    expect(shown()?.sections[0]).toEqual({
      bucket: "in_progress",
      ids: ["a", "new", "b"],
    });
  });

  it("is read when shown, kept on the device, and shown from it offline", async () => {
    const host = new FakeHost();
    host.api.on("GET", order, { orders: { done: ["b", "a"] } });
    const first = setup(host);
    const shown = first.watch({ topic: "taskOrder", group: "g" });
    await first.time.pass(100);
    expect(shown()).toEqual({ orders: { done: ["b", "a"] }, sections: none });
    first.core.close();

    host.api.on("GET", order, offline());
    const again = setup(host);
    const kept = again.watch({ topic: "taskOrder", group: "g" });
    await again.time.pass(100);
    expect(kept()).toEqual({ orders: { done: ["b", "a"] }, sections: none });
  });

  it("puts the dropped cards in the slots they held, a hidden Task keeping its own", async () => {
    const t = setup();
    t.api.on("GET", order, { orders: { done: ["a", "hidden", "b"] } });
    t.api.on("PUT", `${order}/done`, { orders: {} });
    const shown = t.watch({ topic: "taskOrder", group: "g" });
    await t.time.pass(100);
    await t.drop("done", ["b", "a"]);
    expect(t.api.seen("PUT", `${order}/done`)[0]!.body).toEqual({
      ids: ["b", "hidden", "a"],
    });
    await t.time.pass(100);
    expect(shown()).toEqual({ orders: { done: ["b", "hidden", "a"] }, sections: none });
  });

  it("keeps a drop when a read that began before it answers later", async () => {
    const t = setup();
    t.api.on("GET", order, { orders: { needs_review: ["a", "b"] } });
    t.api.on("PUT", `${order}/needs_review`, { orders: {} });
    const release = t.api.hold("GET", order);
    const shown = t.watch({ topic: "taskOrder", group: "g" });
    await t.time.pass(100);
    await t.drop("needs_review", ["b", "a"]);
    release();
    await t.time.pass(100);
    expect(shown()).toEqual({ orders: { needs_review: ["b", "a"] }, sections: none });
  });

  it("writes one drop at a time per bucket, the newest waiting one only", async () => {
    const t = setup();
    t.api.on("GET", order, { orders: {} });
    t.api.on("PUT", `${order}/needs_review`, { orders: {} });
    const release = t.api.hold("PUT", `${order}/needs_review`);
    const first = t.drop("needs_review", ["b", "a"]);
    await t.time.pass(100);
    const replaced = t.drop("needs_review", ["a", "b"]);
    const newest = t.drop("needs_review", ["c", "a", "b"]);
    await t.time.pass(100);
    // The newer drops wait for the one under way: it cannot overtake them.
    expect(t.api.seen("PUT", `${order}/needs_review`)).toHaveLength(1);
    expect(await replaced).toBeNull();
    release();
    await t.time.pass(100);
    expect(await first).toBeNull();
    expect(await newest).toBeNull();
    expect(t.api.seen("PUT", `${order}/needs_review`).map((r) => r.body)).toEqual([
      { ids: ["b", "a"] },
      { ids: ["c", "a", "b"] },
    ]);
  });

  it("keeps the placed order when its save fails, and says it failed", async () => {
    const t = setup();
    t.api.on("GET", order, { orders: {} });
    t.api.on("PUT", `${order}/done`, json(500, { error: "unavailable" }));
    const shown = t.watch({ topic: "taskOrder", group: "g" });
    await t.time.pass(100);
    await expect(t.drop("done", ["a"])).rejects.toMatchObject({ code: "unavailable" });
    await t.time.pass(100);
    expect(shown()).toEqual({ orders: { done: ["a"] }, sections: none });
  });
});

describe("a Group's Task-board arrangement, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", order, { orders: { done: ["a"] } });
    t.watch({ topic: "taskOrder", group: "g" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path === order
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll('"a"', '"z"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
