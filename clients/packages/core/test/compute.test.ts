import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { accountDbName } from "../src/account.ts";
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

function legacyDeletionHost(value: unknown = "legacy-request") {
  const host = new FakeHost();
  const db = NodeSql.memory(true);
  db.exec(`CREATE TABLE doc (name TEXT PRIMARY KEY, json TEXT NOT NULL, read_at INTEGER NOT NULL);
    CREATE TABLE meta (key TEXT PRIMARY KEY, json TEXT NOT NULL); PRAGMA user_version = 1;`);
  db.run("INSERT INTO meta (key, json) VALUES (?, ?)", [
    `computeDeletion:${WS}:w1`,
    JSON.stringify(value),
  ]);
  host.dbs.set(accountDbName("https://api.comma.test", "user-1"), db);
  return host;
}

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
    const stop = client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return Object.assign(() => values.get(k) as T, { stop });
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
    const limited = t2.watch<ComputeValue>({ topic: "compute" });
    t2.api.on("POST", `${base}/workloads`, offline());
    await t2.time.pass(100);
    const failed = expect(
      t2.client.call("compute.create", { workspace: WS, environment: "env" })
    ).rejects.toMatchObject({ code: "network" });
    await t2.time.pass(100);
    await failed;
    const requestId = limited().creation?.requestId;
    const alreadyRead = t2.api.seen("GET", base).length;
    await t2.time.pass(60_000, 5_000);
    expect(t2.api.seen("GET", base)).toHaveLength(alreadyRead + 4);
    expect(limited().observationPaused).toBe(true);
    expect(limited().creation?.requestId).toBe(requestId);
    await t2.client.call("compute.refresh", {});
    await t2.time.pass(100);
    expect(limited().observationPaused).toBe(false);
    expect(limited().creation?.requestId).toBe(requestId);
  });

  it("shows a workload's problem, and a problem code it does not know as `other`", async () => {
    const t = setup();
    t.api.on(
      "GET",
      base,
      projection([
        { ...workload("w1"), problem: { code: "host_unreachable", retryable: true } },
        { ...workload("w2"), problem: { code: "disk_on_fire", retryable: false } },
        { ...workload("w3", "ready"), problem: null },
      ])
    );
    const shown = t.watch<ComputeValue>({ topic: "compute" });
    await t.time.pass(100);
    expect(shown().projection?.workloads.map((w) => w.problem)).toEqual([
      { code: "host_unreachable", retryable: true },
      { code: "other", retryable: false },
      null,
    ]);
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

  it("drops overlapping background ticks instead of queueing reads after a held ready response", async () => {
    const t = setup();
    let hold = false;
    let release: (() => void) | undefined;
    t.api.on("GET", base, async () => {
      if (hold && !release)
        await new Promise<void>((resolve) => {
          release = resolve;
        });
      return json(200, projection([workload("w1", hold ? "ready" : "starting")]));
    });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    hold = true;
    const pending = t.client.call("compute.observe", {});
    await t.time.pass(100);
    expect(t.api.seen("GET", base)).toHaveLength(2);
    const tick = t.client.call("compute.observe", {});
    await t.time.pass(5_000, 500);
    const nextTick = t.client.call("compute.observe", {});
    await t.time.pass(5_000, 500);
    release!();
    await t.time.pass(100);
    await Promise.all([pending, tick, nextTick]);
    expect(shown().projection?.workloads[0]?.phase).toBe("ready");
    expect(t.api.seen("GET", base)).toHaveLength(2);
    t.client.close();
    await t.time.pass(100);
    expect(t.api.seen("GET", base)).toHaveLength(2);
  });

  it("does not start an off-page deletion read after the visible topic stops during a shared page read", async () => {
    const t = setup();
    let hold = false;
    let omitted = false;
    let release: (() => void) | undefined;
    t.api.on("GET", base, async () => {
      if (hold)
        await new Promise<void>((resolve) => {
          release = resolve;
        });
      return json(200, projection(omitted ? [] : [workload("w1", "ready")]));
    });
    t.api.on("POST", `${base}/workloads/w1/deletion`, offline());
    t.api.on("GET", `${base}/workloads/w1`, { workload: workload("w1", "ready") });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const failure = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "network" });
    await t.time.pass(100);
    await failure;
    const requestId = shown().deletion?.requestId;
    hold = true;
    const pending = t.client.call("compute.observe", {});
    await t.time.pass(100);
    shown.stop();
    await t.time.pass(100);
    omitted = true;
    release!();
    await t.time.pass(100);
    await pending;
    expect(t.api.seen("GET", `${base}/workloads/w1`)).toHaveLength(0);
    hold = false;
    const reopened = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    expect(reopened().deletion).toMatchObject({
      requestId,
      generation: 1,
      uncertain: true,
    });
    expect(t.api.seen("GET", `${base}/workloads/w1`)).toHaveLength(1);
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
    again.api.on("GET", base, projection([workload("w9", "ready")]));
    await again.client.call("compute.refresh", {});
    await again.time.pass(100);
    expect(later().projection?.workloads).toMatchObject([{ id: "w9" }]);
    expect(later().accepted).toBeNull();
  });

  it("settles a recovered creation whose durable receipt is already retired", async () => {
    const host = new FakeHost();
    const first = setup(host);
    first.api.on("GET", base, projection([]));
    first.api.on("POST", `${base}/workloads`, offline());
    first.watch({ topic: "compute" });
    await first.time.pass(100);
    const failed = expect(
      first.client.call("compute.create", { workspace: WS, environment: "env" })
    ).rejects.toMatchObject({ code: "network" });
    await first.time.pass(100);
    await failed;
    const sent = first.api.seen("POST", `${base}/workloads`)[0]!.body as {
      request_id: string;
    };
    first.core.close();

    const again = setup(host);
    again.api.on("GET", base, projection([]));
    again.api.on("GET", `${base}/requests/${sent.request_id}`, {
      workload: workload("w9", "cloud_retired"),
    });
    const shown = again.watch<ComputeValue>({ topic: "compute" });
    await again.time.pass(100);
    expect(shown()).toMatchObject({ creation: null, accepted: null, error: false });
  });

  it("lets a completed deletion retire the accepted creation snapshot", async () => {
    const t = setup();
    const ready = workload("w1", "ready");
    const rows: unknown[] = [];
    let current = ready;
    t.api.on("GET", base, () => json(200, projection(rows)));
    t.api.on("POST", `${base}/workloads`, { workload: ready });
    t.api.on("GET", `${base}/workloads/w1`, () => json(200, { workload: current }));
    const shown = t.watch<ComputeValue>({ topic: "compute", after: "w0" });
    await t.time.pass(100);
    const created = t.client.call("compute.create", {
      workspace: WS,
      environment: "env",
    });
    await t.time.pass(100);
    await created;
    expect(shown().accepted?.id).toBe("w1");

    // Another client finishes deletion; the next list omits the durable receipt.
    current = { ...ready, phase: "deleted", revision: 2 };
    await t.client.call("compute.refresh", {});
    await t.time.pass(100);
    expect(shown().accepted).toBeNull();
    expect(shown().projection?.workloads).toEqual([]);
  });

  it("keeps an accepted deletion visible while cleanup needs the original device", async () => {
    const t = setup();
    const ready = workload("w1", "ready");
    const deleting = {
      ...ready,
      phase: "deleting",
      revision: 2,
      deletion: {
        request_id: "delete-request",
        phase: "waiting_original_device",
        error: "original_device_offline",
      },
    };
    t.api.on("GET", base, projection([]));
    t.api.on("POST", `${base}/workloads`, { workload: ready });
    let current = deleting;
    t.api.on("GET", `${base}/workloads/w1`, () => json(200, { workload: current }));
    t.api.on("POST", `${base}/workloads/w1/deletion`, () =>
      json(200, { workload: current })
    );
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const created = t.client.call("compute.create", {
      workspace: WS,
      environment: "env",
    });
    await t.time.pass(100);
    await created;
    const deleted = t.client.call("compute.delete", {
      workspace: WS,
      id: "w1",
      generation: 1,
      request: "delete-request",
    });
    await t.time.pass(100);
    await deleted;
    expect(shown().accepted).toMatchObject({
      id: "w1",
      deletion: { error: "original_device_offline" },
    });

    current = {
      ...deleting,
      phase: "deleted",
      deletion: { ...deleting.deletion, phase: "complete" },
    };
    const completed = t.client.call("compute.delete", {
      workspace: WS,
      id: "w1",
      generation: 1,
      request: "delete-request",
    });
    await t.time.pass(100);
    await completed;
    expect(shown().accepted).toBeNull();
    await t.client.call("compute.refresh", {});
    await t.time.pass(100);
    expect(shown().accepted).toBeNull();
  });

  it("observes a lost deletion reply after restart with one page and one exact target read", async () => {
    const host = new FakeHost();
    const first = setup(host);
    first.api.on("GET", base, projection([workload("w1", "ready")]));
    first.api.on("POST", `${base}/workloads/w1/deletion`, offline());
    first.watch({ topic: "compute", shared: "1" });
    await first.time.pass(100);
    const failure = expect(
      first.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "network" });
    await first.time.pass(100);
    await failure;
    const sent = first.api.seen("POST", `${base}/workloads/w1/deletion`)[0]!.body as {
      request_id: string;
    };
    first.core.close();

    const again = setup(host);
    again.api.on("GET", base, projection([]));
    let current = {
      ...workload("w1", "deleting"),
      deletion: {
        request_id: sent.request_id,
        generation: 1,
        phase: "waiting_original_device",
      },
    };
    again.api.on("GET", `${base}/workloads/w1`, () => json(200, { workload: current }));
    const shown = again.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await again.time.pass(100);
    expect(shown().deletion).toMatchObject({
      requestId: sent.request_id,
      generation: 1,
      uncertain: false,
      workload: { phase: "deleting" },
    });
    const before = again.api.seen("GET", base).length;
    current = {
      ...current,
      phase: "deleted",
      deletion: { ...current.deletion, phase: "complete" },
    };
    await again.client.call("compute.observe", {});
    await again.time.pass(100);
    expect(again.api.seen("GET", base)).toHaveLength(before + 1);
    expect(again.api.seen("GET", `${base}/workloads/w1`)).toHaveLength(2);
    expect(shown().deletion?.workload?.phase).toBe("deleted");
    const db = host.dbs.get(accountDbName("https://api.comma.test", "user-1"))!;
    const stored = JSON.parse(
      db.all("SELECT json FROM meta WHERE key = ?", [
        `computeDeletion:${WS}:w1`,
      ])[0]![0] as string
    );
    expect(stored).toMatchObject({
      requestId: sent.request_id,
      generation: 1,
      terminal: { phase: "complete" },
    });
    expect(stored.workload).toBeUndefined();
    expect(again.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(1);
    await again.client.call("compute.observe", {});
    expect(again.api.seen("GET", base)).toHaveLength(before + 1);
    // A stale page cannot reverse a matching owner receipt or revive its completed row.
    again.api.on("GET", base, projection([workload("w1", "ready")]));
    await again.client.call("compute.refresh", {});
    await again.time.pass(100);
    expect(shown().deletion?.workload?.phase).toBe("deleted");
  });

  it("does not treat a post-commit 403, list omission or exact 404 as deletion refusal or completion", async () => {
    const t = setup();
    t.api.on("GET", base, projection([workload("w1", "ready")]));
    t.api.on("POST", `${base}/workloads/w1/deletion`, () =>
      json(403, { error: "forbidden" })
    );
    t.api.on("GET", `${base}/workloads/w1`, () => json(404, { error: "not_found" }));
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const failure = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ status: 403 });
    await t.time.pass(100);
    await failure;
    t.api.on("GET", base, projection([]));
    await t.client.call("compute.observe", {});
    await t.time.pass(100);
    expect(shown().deletion).toMatchObject({
      workloadId: "w1",
      generation: 1,
      uncertain: true,
    });
    const requestId = shown().deletion!.requestId;
    const queryOnly = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "deletion_uncertain" });
    await t.time.pass(100);
    await queryOnly;
    expect(t.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(1);
    expect(shown().deletion?.canContinue).toBe(false);
    t.api.on("GET", `${base}/workloads/w1`, {
      workload: {
        ...workload("w1", "cloud_retired"),
        deletion: { request_id: requestId, generation: 1, phase: "cloud_retired" },
      },
    });
    await t.client.call("compute.observe", {});
    await t.time.pass(100);
    expect(shown().deletion).toMatchObject({
      uncertain: false,
      workload: { phase: "cloud_retired", deletion: { phase: "cloud_retired" } },
    });
  });

  it("keeps an uncertain deletion on its original generation and permits unrelated targets", async () => {
    const t = setup();
    t.api.on(
      "GET",
      base,
      projection([workload("w1", "ready"), workload("w2", "ready")])
    );
    t.api.on("POST", `${base}/workloads/w1/deletion`, offline());
    t.api.on("GET", `${base}/workloads/w1`, {
      workload: { ...workload("w1", "ready"), generation: 2 },
    });
    t.api.on("POST", `${base}/workloads/w2/deletion`, {
      workload: workload("w2", "deleting"),
    });
    t.watch({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const first = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "network" });
    await t.time.pass(100);
    await first;
    const later = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 2 })
    ).rejects.toMatchObject({ code: "deletion_uncertain" });
    await t.time.pass(100);
    await later;
    expect(t.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(1);
    const unrelated = t.client.call("compute.delete", {
      workspace: WS,
      id: "w2",
      generation: 1,
    });
    await t.time.pass(100);
    await unrelated;
    expect(t.api.seen("POST", `${base}/workloads/w2/deletion`)).toHaveLength(1);
  });

  it("keeps legacy request ids query-only until an exact owner receipt supplies their generation", async () => {
    const host = legacyDeletionHost();
    const t = setup(host);
    t.api.on("GET", base, projection([workload("w1", "ready")]));
    t.api.on("GET", `${base}/workloads/w1`, {
      workload: { ...workload("w1", "ready"), generation: 2 },
    });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const failure = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 2 })
    ).rejects.toMatchObject({ code: "deletion_uncertain" });
    await t.time.pass(100);
    await failure;
    expect(t.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(0);
    expect(shown().deletion).toMatchObject({
      requestId: "legacy-request",
      uncertain: true,
    });
    expect(shown().deletion?.generation).toBeUndefined();
    t.api.on("GET", base, projection([]));
    t.api.on("GET", `${base}/workloads/w1`, {
      workload: {
        ...workload("w1", "deleted"),
        deletion: { request_id: "legacy-request", generation: 1, phase: "complete" },
      },
    });
    await t.client.call("compute.observe", {});
    await t.time.pass(100);
    expect(shown().deletion).toMatchObject({
      generation: 1,
      uncertain: false,
      workload: { phase: "deleted" },
    });
  });

  it.each([
    ["ID-only", "legacy-request"],
    ["normalized", { workloadId: "w1", requestId: "legacy-request", uncertain: true }],
  ])(
    "uses the same %s legacy request after a fresh confirmation and retains unknown generation until a receipt",
    async (_label, saved) => {
      const host = legacyDeletionHost(saved);
      const t = setup(host);
      const ready = {
        ...workload("w1", "ready"),
        generation: 2,
        actions: { rename: true, delete: true },
      };
      t.api.on("GET", base, projection([ready]));
      t.api.on("GET", `${base}/workloads/w1`, { workload: ready });
      t.api.on("POST", `${base}/workloads/w1/deletion`, offline());
      const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
      await t.time.pass(100);
      const failed = expect(
        t.client.call("compute.delete", {
          workspace: WS,
          id: "w1",
          generation: 2,
          confirmLegacy: true,
        })
      ).rejects.toMatchObject({ code: "deletion_uncertain" });
      await t.time.pass(100);
      await failed;
      expect(
        t.api
          .seen("POST", `${base}/workloads/w1/deletion`)
          .map((request) => request.body)
      ).toEqual([{ request_id: "legacy-request", generation: 2 }]);
      expect(shown().deletion).toMatchObject({
        requestId: "legacy-request",
        uncertain: true,
      });
      expect(shown().deletion?.generation).toBeUndefined();
      const db = host.dbs.get(accountDbName("https://api.comma.test", "user-1"))!;
      const stored = JSON.parse(
        db.all("SELECT json FROM meta WHERE key = ?", [
          `computeDeletion:${WS}:w1`,
        ])[0]![0] as string
      );
      expect(stored.generation).toBeUndefined();
      t.core.close();
      const again = setup(host);
      again.api.on("GET", base, projection([]));
      again.api.on("GET", `${base}/workloads/w1`, {
        workload: {
          ...ready,
          phase: "deleting",
          revision: 2,
          deletion: {
            request_id: "legacy-request",
            generation: 2,
            phase: "settling_work",
          },
        },
      });
      const recovered = again.watch<ComputeValue>({ topic: "compute", shared: "1" });
      await again.time.pass(100);
      expect(recovered().deletion).toMatchObject({
        requestId: "legacy-request",
        generation: 2,
        uncertain: false,
      });
      expect(again.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(1);
    }
  );

  it("recovers a legacy owner's original accepted generation instead of submitting the freshly offered generation", async () => {
    const t = setup(
      legacyDeletionHost({
        workloadId: "w1",
        requestId: "legacy-request",
        uncertain: true,
      })
    );
    t.api.on("GET", base, projection([{ ...workload("w1", "ready"), generation: 2 }]));
    t.api.on("GET", `${base}/workloads/w1`, {
      workload: {
        ...workload("w1", "deleting"),
        deletion: {
          request_id: "legacy-request",
          generation: 1,
          phase: "waiting_original_device",
        },
      },
    });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const request = t.client.call("compute.delete", {
      workspace: WS,
      id: "w1",
      generation: 2,
      confirmLegacy: true,
    });
    await t.time.pass(100);
    expect(await request).toMatchObject({
      deletion: { request_id: "legacy-request", generation: 1 },
    });
    expect(shown().deletion).toMatchObject({
      requestId: "legacy-request",
      generation: 1,
      uncertain: false,
    });
    expect(t.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(0);
  });

  it.each([
    ["inaccessible owner", 403, null],
    ["missing owner", 404, null],
    [
      "different target",
      200,
      {
        ...workload("w-other", "ready"),
        generation: 2,
        actions: { rename: true, delete: true },
      },
    ],
    [
      "changed generation",
      200,
      {
        ...workload("w1", "ready"),
        generation: 3,
        actions: { rename: true, delete: true },
      },
    ],
    [
      "no delete permission",
      200,
      {
        ...workload("w1", "ready"),
        generation: 2,
        actions: { rename: true, delete: false },
      },
    ],
    [
      "retired target",
      200,
      {
        ...workload("w1", "cloud_retired"),
        generation: 2,
        actions: { rename: true, delete: true },
      },
    ],
    [
      "another deletion",
      200,
      {
        ...workload("w1", "deleting"),
        generation: 2,
        actions: { rename: true, delete: true },
        deletion: {
          request_id: "another-request",
          generation: 2,
          phase: "settling_work",
        },
      },
    ],
  ])("refuses fresh legacy deletion for %s", async (_label, status, current) => {
    const t = setup(legacyDeletionHost());
    t.api.on("GET", base, projection([{ ...workload("w1", "ready"), generation: 2 }]));
    t.api.on("GET", `${base}/workloads/w1`, () =>
      json(status as number, current ? { workload: current } : { error: "not_found" })
    );
    t.watch({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const failed = expect(
      t.client.call("compute.delete", {
        workspace: WS,
        id: "w1",
        generation: 2,
        confirmLegacy: true,
      })
    ).rejects.toMatchObject({ code: "deletion_uncertain" });
    await t.time.pass(100);
    await failed;
    expect(t.api.seen("POST", `${base}/workloads/w1/deletion`)).toHaveLength(0);
  });

  it("refreshes an all-ready page after a mutation reply is lost", async () => {
    const t = setup();
    let rows = [workload("w1", "ready")];
    t.api.on("GET", base, () => json(200, projection(rows)));
    t.api.on("POST", `${base}/workloads/w1/retry`, () => {
      rows = [{ ...workload("w1", "starting"), revision: 2 }];
      return offline();
    });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const failure = expect(
      t.client.call("compute.retry", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "network" });
    await t.time.pass(100);
    await failure;
    expect(shown().projection?.workloads[0]?.phase).toBe("starting");
    expect(t.api.seen("GET", base)).toHaveLength(2);
  });

  it("continues a lost-before-dispatch deletion only after an exact positive owner read with the same id and generation", async () => {
    const t = setup();
    const ready = workload("w1", "ready");
    let committed = false;
    t.api.on("GET", base, projection([ready]));
    t.api.on("GET", `${base}/workloads/w1`, { workload: ready });
    t.api.on("POST", `${base}/workloads/w1/deletion`, (request) => {
      if (!committed) return offline();
      const body = request.body as { request_id: string; generation: number };
      return json(200, {
        workload: {
          ...ready,
          phase: "deleting",
          revision: 2,
          deletion: {
            request_id: body.request_id,
            generation: body.generation,
            phase: "settling_work",
          },
        },
      });
    });
    const shown = t.watch<ComputeValue>({ topic: "compute", shared: "1" });
    await t.time.pass(100);
    const first = expect(
      t.client.call("compute.delete", { workspace: WS, id: "w1", generation: 1 })
    ).rejects.toMatchObject({ code: "network" });
    await t.time.pass(100);
    await first;
    expect(shown().deletion).toMatchObject({
      uncertain: true,
      canContinue: true,
      generation: 1,
    });
    committed = true;
    const continued = t.client.call("compute.delete", {
      workspace: WS,
      id: "w1",
      generation: 1,
    });
    await t.time.pass(100);
    await continued;
    const posts = t.api.seen("POST", `${base}/workloads/w1/deletion`);
    expect(posts).toHaveLength(2);
    expect(posts[1]!.body).toEqual(posts[0]!.body);
    expect(t.api.seen("GET", `${base}/workloads/w1`)).toHaveLength(1);
    expect(shown().deletion).toMatchObject({
      uncertain: false,
      workload: { phase: "deleting" },
    });
  });

  it("reuses a deletion's request id until the server answers", async () => {
    const t = setup();
    t.api.on("GET", base, projection([workload("w1", "ready")]));
    let up = false;
    t.api.on("GET", `${base}/workloads/w1`, { workload: workload("w1", "ready") });
    t.api.on("POST", `${base}/workloads/w1/deletion`, () =>
      up ? json(200, { workload: { ...workload("w1", "deleting") } }) : offline()
    );
    t.watch({ topic: "compute" });
    await t.time.pass(100);
    const params = { workspace: WS, id: "w1", generation: 1 };
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
