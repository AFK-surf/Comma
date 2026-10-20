import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ResolvedWorkspace } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  offline,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const LIST = "/v1/comma/workspaces";
const ws = (id: string) => ({ id, group_id: `grp_${id}`, name: id });

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as ResolvedWorkspace;
  };
  core.observeSession(signedIn());
  return { core, client, time: host.time!, api: host.api, watch };
}

describe("the workspace a surface works in", () => {
  it("loads a workspace already watched before the session is ready", async () => {
    const t = setup();
    t.core.observeSession(signedOut());
    t.api.on("GET", LIST, { data: [ws("a")] });
    const active = t.watch({ topic: "workspace" });
    await t.time.pass(100);
    expect(active().status).toBe("loading");

    t.core.observeSession(signedIn("user-1", { generation: 3 }));
    await t.time.pass(100);
    expect(active()).toEqual({
      status: "ready",
      workspace: { id: "a", groupId: "grp_a", name: "a" },
      selected: false,
    });
  });

  it("is the preferred one when the account has it, else the first", async () => {
    const t = setup();
    t.api.on("GET", LIST, { data: [ws("a"), ws("b")] });
    const kept = t.watch({ topic: "workspace", prefer: "b" });
    const gone = t.watch({ topic: "workspace", prefer: "deleted" });
    await t.time.pass(100);
    expect(kept()).toEqual({
      status: "ready",
      workspace: { id: "b", groupId: "grp_b", name: "b" },
    });
    expect(gone()).toEqual({
      status: "ready",
      workspace: { id: "a", groupId: "grp_a", name: "a" },
    });
  });

  it("is none when the account has no workspace, and says when the list could not be read", async () => {
    const t = setup();
    t.api.on("GET", LIST, { data: [] });
    const none = t.watch({ topic: "workspace", prefer: "a" });
    await t.time.pass(100);
    expect(none()).toEqual({ status: "ready", workspace: null });

    const u = setup();
    u.api.on("GET", LIST, () => offline());
    const failed = u.watch({ topic: "workspace", prefer: "a" });
    await u.time.pass(100);
    expect(failed()).toEqual({ status: "error", workspace: null });
  });
});

describe("the workspace the app works in", () => {
  it("is the selected one on every surface that prefers none, until the account signs out", async () => {
    const t = setup();
    t.api.on("GET", LIST, { data: [ws("a"), ws("b")] });
    const active = t.watch({ topic: "workspace" });
    const preferred = t.watch({ topic: "workspace", prefer: "a" });
    await t.time.pass(100);
    expect(active().workspace?.id).toBe("a");

    await t.client.call("workspace.select", { workspace: "b" });
    await t.time.pass(100);
    expect(active().workspace?.id).toBe("b");
    expect(preferred().workspace?.id).toBe("a");

    t.core.observeSession(signedOut());
    await t.time.pass(100);
    t.core.observeSession(signedIn("user-1", { generation: 3 }));
    // A surface shown after signing in again, preferring one the account does not have.
    const again = t.watch({ topic: "workspace", prefer: "deleted" });
    await t.time.pass(100);
    expect(again().workspace?.id).toBe("a");
  });

  it("falls back to the first when the selected one is gone", async () => {
    const t = setup();
    t.api.on("GET", LIST, { data: [ws("a"), ws("b")] });
    const active = t.watch({ topic: "workspace" });
    await t.time.pass(100);
    await t.client.call("workspace.select", { workspace: "deleted" });
    await t.time.pass(100);
    expect(active().workspace?.id).toBe("a");
  });

  it("refuses a selection without a workspace", async () => {
    const t = setup();
    await expect(
      t.client.call("workspace.select", { workspace: "" })
    ).rejects.toMatchObject({
      code: "invalid_params",
    });
  });
});

describe("the workspace a surface works in, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", LIST, { data: [ws("a")] });
    t.watch({ topic: "workspace", prefer: "a" });
    await t.time.pass(100);
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
