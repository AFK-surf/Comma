import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ComputeValue } from "../src/contract.ts";
import type { CoreLimits } from "../src/limits.ts";
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

const WS = "wsp_compute";
const base = `/v1/comma/workspaces/${WS}/compute`;
const workload = (id: string, phase = "waiting_connection") => ({
  id,
  environment_id: "env",
  kind: "shell",
  desired_state: "ready",
  observed_state: "pending",
  phase,
  revision: 1,
  generation: 1,
});
const projection = (workloads: unknown[]) => ({
  environments: [
    { id: "env", desired_state: "ready", observed_state: "ready", can_create: true },
  ],
  workloads,
});

function setup(host = new FakeHost(), limits?: Partial<CoreLimits>) {
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: WS, group_id: "g", name: "Main" }],
  });
  const core = startTestCore(host, limits ? { limits } : {});
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

describe("Settings › Compute", () => {
  it("reads every 5 s while a workload prepares, at most a visit's limit of reads, and stops when it is ready", async () => {
    const t = setup();
    let rows = [workload("w1")];
    t.api.on("GET", base, () => json(200, projection(rows)));
    t.watch({ topic: "compute" });
    await t.time.pass(100);
    await t.time.pass(10_000, 500);
    expect(t.api.seen("GET", base)).toHaveLength(3);
    rows = [workload("w1", "ready")];
    await t.time.pass(5_000, 500);
    const reads = t.api.seen("GET", base).length;
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", base)).toHaveLength(reads);

    // The limit is 60 reads a visit (limits.test.ts); 5 reach it the same way.
    const t2 = setup(undefined, { computeReadsPerVisit: 5 });
    t2.api.on("GET", base, projection([workload("w1")]));
    t2.watch({ topic: "compute" });
    await t2.time.pass(60_000, 5_000);
    expect(t2.api.seen("GET", base)).toHaveLength(5);
  });

  it("lets the page drive reads when `shared`", async () => {
    const t = setup();
    t.api.on("GET", base, projection([workload("w1")]));
    t.watch({ topic: "compute", shared: "1" });
    await t.time.pass(30_000, 1_000);
    expect(t.api.seen("GET", base)).toHaveLength(1);
    await t.client.call("compute.observe", {});
    await t.time.pass(100);
    expect(t.api.seen("GET", base)).toHaveLength(2);
  });

  it("keeps a creation's request id on the device before sending, and asks again with it after no answer", async () => {
    const host = new FakeHost();
    const first = setup(host);
    first.api.on("GET", base, projection([]));
    first.api.on("POST", `${base}/workloads`, offline());
    const shown = first.watch<ComputeValue>({ topic: "compute" });
    await first.time.pass(100);
    const created = expect(
      first.client.call("compute.create", {
        workspace: WS,
        environment: "env",
        name: "Build box",
      })
    ).rejects.toMatchObject({ code: "network" });
    await first.time.pass(100);
    await created;
    const sent = first.api.seen("POST", `${base}/workloads`)[0]!.body as {
      request_id: string;
    };
    expect(shown().creation).toMatchObject({
      requestId: sent.request_id,
      name: "Build box",
    });
    first.core.close();

    // The next run asks for that creation by its id; the server made it: it shows, and the id is let go.
    const again = setup(host);
    again.api.on("GET", base, projection([]));
    again.api.on("GET", `${base}/requests/${sent.request_id}`, {
      workload: workload("w9", "ready"),
    });
    const later = again.watch<ComputeValue>({ topic: "compute" });
    await again.time.pass(100);
    expect(later()).toMatchObject({ creation: null, accepted: { id: "w9" } });
  });

  it("reuses a deletion's request id until the server answers", async () => {
    const t = setup();
    t.api.on("GET", base, projection([workload("w1", "ready")]));
    let up = false;
    t.api.on("POST", `${base}/workloads/w1/deletion`, () =>
      up ? json(200, { workload: { ...workload("w1", "deleting") } }) : offline()
    );
    t.watch({ topic: "compute" });
    await t.time.pass(100);
    const params = { workspace: WS, id: "w1", revision: 1, generation: 1 };
    const failed = expect(
      t.client.call("compute.delete", params)
    ).rejects.toMatchObject({
      code: "network",
    });
    await t.time.pass(100);
    await failed;
    up = true;
    const deleted = t.client.call("compute.delete", params);
    await t.time.pass(100);
    await deleted;
    const ids = t.api
      .seen("POST", `${base}/workloads/w1/deletion`)
      .map((r) => (r.body as { request_id: string }).request_id);
    expect(ids[0]).toBe(ids[1]);
  });
});

describe("Settings › Compute, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", base, projection([workload("w1")]));
    t.watch({ topic: "compute" });
    await t.time.pass(10_100, 500);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(base)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replace('"w1"', '"w2"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
