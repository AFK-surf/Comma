import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskPreviewValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const pathOf = (conversation: string) =>
  `/v1/comma/groups/grp_1/conversations/${conversation}/preview`;
const previewOf = (conversation: string, status = "running") => ({
  activity_status: "working",
  freshness: { state: "fresh" },
  group_id: "grp_1",
  id: conversation,
  kind: "agent_task",
  status,
  title: `Task ${conversation}`,
  updated_at: 1,
});
const card = (conversation: string, read: number) => ({
  topic: "taskPreview",
  group: "grp_1",
  conversation,
  read: String(read),
});

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops: (() => void)[] = [];
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    stops.push(
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as TaskPreviewValue;
  };
  const closeAll = async () => {
    for (const stop of stops.splice(0)) stop();
    await host.time!.pass(61_000, 1_000);
  };
  core.observeSession(signedIn());
  return { time: host.time!, api: host.api, watch, closeAll };
}

describe("a task's preview", () => {
  it("is read again on a later opening only once a running task's is 20 seconds old", async () => {
    const t = setup();
    t.api.on("GET", pathOf("cnv_1"), previewOf("cnv_1"));
    const first = t.watch(card("cnv_1", 1));
    await t.time.pass(10);
    expect(first()).toEqual({ status: "ready", preview: previewOf("cnv_1") });

    const second = t.watch(card("cnv_1", 2));
    await t.time.pass(10);
    expect(second()).toEqual({ status: "ready", preview: previewOf("cnv_1") });
    expect(t.api.seen("GET", pathOf("cnv_1"))).toHaveLength(1);

    await t.time.pass(20_000, 5_000);
    t.watch(card("cnv_1", 3));
    await t.time.pass(10);
    expect(t.api.seen("GET", pathOf("cnv_1"))).toHaveLength(2);
  });

  it("keeps an ended task's preview for five minutes", async () => {
    const t = setup();
    t.api.on("GET", pathOf("cnv_1"), previewOf("cnv_1", "completed"));
    t.watch(card("cnv_1", 1));
    await t.time.pass(10);
    await t.time.pass(4 * 60_000, 30_000);
    t.watch(card("cnv_1", 2));
    await t.time.pass(10);
    expect(t.api.seen("GET", pathOf("cnv_1"))).toHaveLength(1);
    await t.time.pass(60_000, 30_000);
    t.watch(card("cnv_1", 3));
    await t.time.pass(10);
    expect(t.api.seen("GET", pathOf("cnv_1"))).toHaveLength(2);
  });

  it("says a task the server no longer shows is revoked, and asks again after any other failure", async () => {
    const t = setup();
    t.api.on("GET", pathOf("cnv_gone"), json(404, { error: "not_found" }));
    t.api.on("GET", pathOf("cnv_hidden"), json(403, { error: "forbidden" }));
    t.api.on("GET", pathOf("cnv_down"), offline());
    const gone = t.watch(card("cnv_gone", 1));
    const hidden = t.watch(card("cnv_hidden", 1));
    const down = t.watch(card("cnv_down", 1));
    await t.time.pass(10);
    expect(gone()).toEqual({ status: "revoked" });
    expect(hidden()).toEqual({ status: "revoked" });
    expect(down()).toEqual({ status: "failed" });

    t.watch(card("cnv_down", 2));
    t.watch(card("cnv_gone", 2));
    await t.time.pass(10);
    expect(t.api.seen("GET", pathOf("cnv_down"))).toHaveLength(2);
    expect(t.api.seen("GET", pathOf("cnv_gone"))).toHaveLength(1);
  });

  it("keeps the 128 most recently shown, and reads an older one again", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/grp_1/conversations/*", (request) =>
      json(200, previewOf(request.path.split("/")[6]!, "completed"))
    );
    for (let index = 0; index < 129; index += 1) t.watch(card(`cnv_${index}`, 1));
    await t.time.pass(100);
    await t.closeAll();
    const reads = (id: string) =>
      t.api.requests.filter((r) => r.path === pathOf(id)).length;
    t.watch(card("cnv_1", 2));
    t.watch(card("cnv_0", 2));
    await t.time.pass(10);
    expect(reads("cnv_1")).toBe(1);
    expect(reads("cnv_0")).toBe(2);
  });
});
