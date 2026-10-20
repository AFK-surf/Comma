import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskSharesValue, TaskShareValue } from "../src/contract.ts";
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
const share = "/v1/comma/groups/g/conversations/t1/share";
const shares = "/v1/comma/groups/g/task-shares";

const link = (
  url = "https://comma.test/s/one",
  extra: Record<string, unknown> = {}
) => ({
  url,
  created_at: 1,
  shared_at: 2,
  message_count: 3,
  artifact_count: 0,
  has_newer_messages: false,
  ...extra,
});
const entry = (id: string) => ({
  conversation: {
    id,
    group_id: "g",
    kind: "agent_task",
    status: "completed",
    title: `Task ${id}`,
  },
  url: `https://comma.test/s/${id}`,
  created_at: 1,
  shared_at: 1_700_000_000,
  message_count: 2,
  artifact_count: 1,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
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
  return { host, core, client, time: host.time!, api: host.api, watch };
}

const dialog = { topic: "taskShare", group: "g", conversation: "t1" };
const params = { group: "g", conversation: "t1" };

describe("a Task's public link", () => {
  it("reads it when the dialog opens, and shows what each change answered", async () => {
    const t = setup();
    const shown = t.watch<TaskShareValue>(dialog);
    await t.time.pass(100);
    // No link: not shared.
    expect(shown()).toEqual({ status: "ready", share: null });

    t.api.on("PUT", share, link());
    const published = (await t.client.call("taskShare.publish", params)) as {
      url: string;
    };
    expect(published.url).toBe("https://comma.test/s/one");
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      share: { url: "https://comma.test/s/one" },
    });

    t.api.on("POST", `${share}/reset`, link("https://comma.test/s/two"));
    await t.client.call("taskShare.reset", params);
    await t.time.pass(100);
    expect(shown()).toMatchObject({ share: { url: "https://comma.test/s/two" } });

    t.api.on("DELETE", share, { revoked: true });
    await t.client.call("taskShare.revoke", params);
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "ready", share: null });
  });

  it("reads it again each time a dialog opens", async () => {
    const t = setup();
    t.api.on("GET", share, link());
    t.watch({ ...dialog, visit: "1" });
    await t.time.pass(100);
    const again = t.watch<TaskShareValue>({ ...dialog, visit: "2" });
    await t.time.pass(100);
    expect(again()).toMatchObject({
      status: "ready",
      share: { url: "https://comma.test/s/one" },
    });
    expect(t.api.seen("GET", share)).toHaveLength(2);
  });

  it("says a failed read failed and reads again on retry", async () => {
    const t = setup();
    t.api.on("GET", share, offline());
    const shown = t.watch<TaskShareValue>(dialog);
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "failed", share: null });
    t.api.on("GET", share, link());
    await t.client.call("taskShare.refresh", params);
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      share: { url: "https://comma.test/s/one" },
    });
  });

  it("keeps the shown link when a change fails", async () => {
    const t = setup();
    t.api.on("GET", share, link());
    t.api.on("POST", `${share}/reset`, json(500, { error: "unavailable" }));
    const shown = t.watch<TaskShareValue>(dialog);
    await t.time.pass(100);
    await expect(t.client.call("taskShare.reset", params)).rejects.toMatchObject({
      code: "unavailable",
    });
    expect(shown()).toMatchObject({
      status: "ready",
      share: { url: "https://comma.test/s/one" },
    });
  });
});

describe("Settings › Shared tasks", () => {
  it("lists a page at a time and drops a link stopped there", async () => {
    const t = setup();
    t.api.on("GET", shares, (r) =>
      json(
        200,
        r.path.includes("cursor=p2")
          ? { data: [entry("t2")], has_more: false, next_cursor: null }
          : { data: [entry("t1")], has_more: true, next_cursor: "p2" }
      )
    );
    const shown = t.watch<TaskSharesValue>({ topic: "taskShares" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      workspace: { id: "wsp" },
      shares: [
        { id: "t1", title: "Task t1", shared_at: 1_700_000_000, artifact_count: 1 },
      ],
      hasMore: true,
      loading: false,
    });
    await t.client.call("taskShares.more", {});
    await t.time.pass(100);
    expect(shown().shares.map((s) => s.id)).toEqual(["t1", "t2"]);

    t.api.on("DELETE", share, { revoked: true });
    await t.client.call("taskShare.revoke", params);
    await t.time.pass(100);
    expect(shown().shares.map((s) => s.id)).toEqual(["t2"]);
  });
});

describe("shared tasks, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", shares, {
      data: [entry("t1")],
      has_more: false,
      next_cursor: null,
    });
    t.watch({ topic: "taskShares" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(shares)
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
