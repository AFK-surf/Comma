import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { CondensedWorkspaceValue } from "../src/contract.ts";
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

const base = (group: string) => `/v1/comma/groups/${group}/condensed-workspace`;
const state = (enabled: boolean, statements: { id: string; text: string }[] = []) => ({
  enabled,
  revision: statements.length,
  statements,
  bytes: 0,
  recommended_max_bytes: 4096,
  max_bytes: 16384,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [
      { id: "ws-1", group_id: "g-1", name: "One" },
      { id: "ws-2", group_id: "g-2", name: "Two" },
    ],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("the Condensed Workspace", () => {
  it("reads the preferred workspace's Group, else the first, and says when it cannot", async () => {
    const t = setup();
    t.api.on(
      "GET",
      base("g-2"),
      state(true, [{ id: "s1", text: "Launch is Friday." }])
    );
    t.api.on("GET", base("g-1"), offline());
    const preferred = t.watch<CondensedWorkspaceValue>({
      topic: "condensedWorkspace",
      prefer: "ws-2",
    });
    const first = t.watch<CondensedWorkspaceValue>({ topic: "condensedWorkspace" });
    await t.time.pass(100);
    expect(preferred()).toMatchObject({
      group: "g-2",
      state: { enabled: true },
      error: false,
    });
    expect(first()).toMatchObject({ group: "g-1", state: null, error: true });
  });

  it("turns it on and edits it with the requests the server expects, showing each answer", async () => {
    const t = setup();
    let current = state(false);
    t.api.on("GET", base("g-1"), () => json(200, current));
    t.api.on("PUT", `${base("g-1")}/settings`, (request) => {
      current = { ...current, enabled: (request.body as { enabled: boolean }).enabled };
      return json(200, current);
    });
    t.api.on("POST", `${base("g-1")}/operations`, () => {
      current = state(true, [{ id: "s1", text: "Launch is Friday." }]);
      return json(200, current);
    });
    const shown = t.watch<CondensedWorkspaceValue>({ topic: "condensedWorkspace" });
    await t.time.pass(100);
    const on = t.client.call("condensedWorkspace.setEnabled", {
      group: "g-1",
      enabled: true,
    });
    await t.time.pass(100);
    await on;
    expect(shown().state?.enabled).toBe(true);
    const added = t.client.call("condensedWorkspace.apply", {
      group: "g-1",
      operations: [{ op: "add", text: "Launch is Friday." }],
    });
    await t.time.pass(100);
    await added;
    expect(t.api.seen("POST", `${base("g-1")}/operations`)[0]!.body).toEqual({
      operations: [{ op: "add", text: "Launch is Friday." }],
    });
    expect(shown().state?.statements).toEqual([
      { id: "s1", text: "Launch is Friday." },
    ]);
    await expect(
      t.client.call("condensedWorkspace.apply", {
        group: "g-1",
        operations: [{ op: "drop" }],
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });
});

describe("the Condensed Workspace, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", base("g-1"), state(false, [{ id: "s1", text: "Old" }]));
    t.watch({ topic: "condensedWorkspace" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path === base("g-1")
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replace('"Old"', '"New"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
