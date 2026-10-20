import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskLabelsValue } from "../src/contract.ts";
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

const G = "grp-a";
const labelsPath = `/v1/comma/groups/${G}/task-labels`;
const catalog = (name: string, policy = "ask") => ({
  approval_policy: policy,
  colors: ["red"],
  labels: [{ color: "red", id: "label-a", name }],
  proposals: [],
});

function setup(host = new FakeHost()) {
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
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("the Task label catalog", () => {
  it("serves every reader of a Group from one read, kept on the device", async () => {
    const t = setup();
    t.api.on("GET", labelsPath, catalog("Bug"));
    const panel = t.watch<TaskLabelsValue>({ topic: "taskLabels", group: G });
    const chips = t.watch<TaskLabelsValue>({
      topic: "taskLabels",
      group: G,
      key: "ids-1",
    });
    await t.time.pass(100);
    expect(panel().catalog?.labels[0]?.name).toBe("Bug");
    expect(chips().catalog?.labels[0]?.name).toBe("Bug");
    expect(t.api.seen("GET", labelsPath).length).toBeLessThanOrEqual(2);
    t.core.close();

    // The next run, offline: the kept catalog shows.
    t.host.api.on("GET", labelsPath, offline());
    const again = setup(t.host);
    const shown = again.watch<TaskLabelsValue>({ topic: "taskLabels", group: G });
    await again.time.pass(100);
    expect(shown()).toMatchObject({
      catalog: { labels: [{ name: "Bug" }] },
      error: true,
    });
  });

  it("reads again when a reader's labels change, and a 'known' reader only while nothing is kept", async () => {
    const t = setup();
    t.api.on("GET", labelsPath, catalog("Bug"));
    t.watch({ topic: "taskLabels", group: G, key: "a" });
    await t.time.pass(100);
    expect(t.api.seen("GET", labelsPath)).toHaveLength(1);
    t.watch({ topic: "taskLabels", group: G, key: "b" });
    await t.time.pass(100);
    expect(t.api.seen("GET", labelsPath)).toHaveLength(2);
    t.watch({ topic: "taskLabels", group: G, mode: "known" });
    await t.time.pass(100);
    expect(t.api.seen("GET", labelsPath)).toHaveLength(2);
  });

  it("reports loading for the first read only, and keeps the labels through a failed read", async () => {
    const t = setup();
    let up = true;
    t.api.on("GET", labelsPath, () => (up ? json(200, catalog("Bug")) : offline()));
    const release = t.api.hold("GET", labelsPath);
    const shown = t.watch<TaskLabelsValue>({ topic: "taskLabels", group: G });
    await t.time.pass(10);
    expect(shown()).toMatchObject({ catalog: null, loading: true });
    release();
    await t.time.pass(100);
    expect(shown()).toMatchObject({ loading: false, error: false });
    up = false;
    await t.client.call("taskLabels.refresh", { group: G }).catch(() => undefined);
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      loading: false,
      error: true,
      catalog: { labels: [{ name: "Bug" }] },
    });
  });

  it("reads the catalog again when asked to refresh, and hands what it read to every reader", async () => {
    const t = setup();
    let name = "Bug";
    t.api.on("GET", labelsPath, () => json(200, catalog(name)));
    const a = t.watch<TaskLabelsValue>({ topic: "taskLabels", group: G, key: "" });
    await t.time.pass(100);
    // A `known` reader rides on the kept catalog.
    const b = t.watch<TaskLabelsValue>({
      topic: "taskLabels",
      group: G,
      key: "",
      mode: "known",
    });
    await t.time.pass(100);
    expect(t.api.seen("GET", labelsPath)).toHaveLength(1);
    name = "Release";
    const refreshed = t.client.call("taskLabels.refresh", { group: G });
    await t.time.pass(100);
    await refreshed;
    expect(t.api.seen("GET", labelsPath)).toHaveLength(2);
    expect(a()).toMatchObject({
      error: false,
      catalog: { labels: [{ name: "Release" }] },
    });
    expect(b().catalog?.labels[0]?.name).toBe("Release");
  });

  it("hands a change's catalog to every reader, with the request the server expects", async () => {
    const t = setup();
    t.api.on("GET", labelsPath, catalog("Bug"));
    t.api.on("POST", `${labelsPath}/proposals/prp_1/resolve`, catalog("Defect"));
    t.api.on("PATCH", `${labelsPath}/policy`, catalog("Defect", "auto"));
    const a = t.watch<TaskLabelsValue>({ topic: "taskLabels", group: G });
    const b = t.watch<TaskLabelsValue>({
      topic: "taskLabels",
      group: G,
      mode: "known",
    });
    await t.time.pass(100);
    const resolved = t.client.call("taskLabels.resolve", {
      group: G,
      proposal: "prp_1",
      decision: "approve",
      autoApprove: true,
    });
    await t.time.pass(100);
    await resolved;
    expect(
      t.api.seen("POST", `${labelsPath}/proposals/prp_1/resolve`)[0]!.body
    ).toEqual({
      decision: "approve",
      auto_approve: true,
    });
    expect(a().catalog?.labels[0]?.name).toBe("Defect");
    expect(b().catalog?.labels[0]?.name).toBe("Defect");
    const policy = t.client.call("taskLabels.setPolicy", { group: G, policy: "auto" });
    await t.time.pass(100);
    await policy;
    expect(t.api.seen("PATCH", `${labelsPath}/policy`)[0]!.body).toEqual({
      approval_policy: "auto",
    });
    expect(a().catalog?.approval_policy).toBe("auto");
  });

  it("shows a chosen policy at once, and the saved one again when the server refuses it", async () => {
    const t = setup();
    t.api.on("GET", labelsPath, catalog("Bug"));
    t.api.on("PATCH", `${labelsPath}/policy`, json(500, { error: "unavailable" }));
    const shown = t.watch<TaskLabelsValue>({ topic: "taskLabels", group: G });
    await t.time.pass(100);
    const release = t.api.hold("PATCH", `${labelsPath}/policy`);
    const chosen = t.client.call("taskLabels.setPolicy", { group: G, policy: "auto" });
    const refused = expect(chosen).rejects.toMatchObject({ status: 500 });
    await t.time.pass(100);
    expect(shown().catalog?.approval_policy).toBe("auto");
    release();
    await t.time.pass(100);
    await refused;
    expect(shown().catalog?.approval_policy).toBe("ask");
  });

  it("replaces a Task's labels with the ids it is given", async () => {
    const t = setup();
    const task = `/v1/comma/groups/${G}/conversations/cnv_1`;
    t.api.on("PATCH", task, { id: "cnv_1", labels: ["label-a"] });
    const assigned = t.client.call("taskLabels.assign", {
      group: G,
      conversation: "cnv_1",
      labels: ["label-a"],
    });
    await t.time.pass(100);
    expect(await assigned).toBeNull();
    expect(t.api.seen("PATCH", task)[0]!.body).toEqual({ labels: ["label-a"] });
    await expect(
      t.client.call("taskLabels.assign", {
        group: G,
        conversation: "cnv_1",
        labels: [""],
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });

  it("counts each label on the Group's first page of Tasks", async () => {
    const t = setup();
    t.api.on("GET", `/v1/comma/groups/${G}/conversations`, {
      data: [{ labels: ["label-a"] }, { labels: ["label-a", "label-b"] }, {}],
    });
    const counts = t.watch<Record<string, number> | null>({
      topic: "taskLabelCounts",
      group: G,
    });
    await t.time.pass(100);
    expect(counts()).toEqual({ "label-a": 2, "label-b": 1 });
  });
});

describe("the Task label catalog, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", labelsPath, catalog("Bug"));
    t.api.on("DELETE", `${labelsPath}/label-a`, { ...catalog("x"), labels: [] });
    t.watch({ topic: "taskLabels", group: G });
    await t.time.pass(100);
    const deleted = t.client.call("taskLabels.delete", { group: G, label: "label-a" });
    await t.time.pass(100);
    await deleted;

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const first = told.find(
      (input) => input.kind === "response" && input.request.path === labelsPath
    )!;
    if (first.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(first.body));
    first.body = base64(new TextEncoder().encode(body.replace('"Bug"', '"Other"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
