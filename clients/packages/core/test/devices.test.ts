import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DevicesValue } from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "wsp_1";
const list = `/v1/comma/workspaces/${WS}/devices`;

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: WS, group_id: "g", name: "Main" }],
  });
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
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  const seconds = () => Math.floor(host.time!.now() / 1000);
  return {
    host,
    core,
    client,
    time: host.time!,
    api: host.api,
    watch,
    unwatch,
    seconds,
  };
}

const device = (
  id: string,
  validFor: number | null,
  extra: Record<string, unknown> = {}
) => ({
  device_id: id,
  name: id,
  status: "connected",
  allows_operations: true,
  device_runtimes:
    validFor === null
      ? []
      : [
          {
            provider: "codex",
            device_runtime_id: `rt_${id}`,
            status: "ready",
            readiness_valid_until: validFor,
          },
        ],
  ...extra,
});

describe("Settings › Devices", () => {
  it("reads every 15 s while shown, shows readiness going stale at its expiry, and stops once let go", async () => {
    const t = setup();
    const valid = t.seconds() + 100;
    t.api.on("GET", list, () =>
      json(200, { devices: [device("a", valid)], next_cursor: null })
    );
    const topic = { topic: "devices", visit: "1" };
    const shown = t.watch<DevicesValue>(topic);
    await t.time.pass(100);
    expect(shown().devices[0]?.device_runtimes[0]?.fresh).toBe(true);
    await t.time.pass(30_000, 1_000);
    expect(t.api.seen("GET", list)).toHaveLength(3);
    await t.time.pass(80_000, 1_000);
    expect(shown().devices[0]?.device_runtimes[0]?.fresh).toBe(false);
    t.unwatch(topic);
    const reads = t.api.seen("GET", list).length;
    await t.time.pass(120_000, 5_000);
    expect(t.api.seen("GET", list)).toHaveLength(reads);
  });

  it("lists a Comma device, and leaves out a row it cannot read rather than failing the page", async () => {
    const t = setup();
    t.api.on("GET", list, () =>
      json(200, {
        devices: [
          device("board", null, { system_info: { client_source: "t-circle" } }),
          { device_id: "broken" },
          device("mac", null),
        ],
        next_cursor: null,
      })
    );
    const shown = t.watch<DevicesValue>({ topic: "devices", visit: "1" });
    await t.time.pass(100);
    expect(shown().failed).toBe(false);
    expect(shown().devices.map((d) => d.device_id)).toEqual(["board", "mac"]);
    expect(shown().devices[0]?.system_info?.client_source).toBe("t-circle");
  });

  it("checks stale runtimes once per visit, two at a time; a check's answer stands over an older read; a list without a visit checks none", async () => {
    const t = setup();
    const expired = t.seconds() - 1;
    const devices = [
      device("a", expired),
      device("b", expired),
      device("c", expired),
      device("d", null),
    ];
    t.api.on("GET", list, () => json(200, { devices, next_cursor: null }));
    const releases: (() => void)[] = [];
    for (const id of ["a", "b", "c"])
      t.api.on("POST", `${list}/${id}/probe`, async () => {
        await new Promise<void>((resolve) => releases.push(resolve));
        return json(200, device(id, t.seconds() + 600));
      });
    const probes = () => t.api.requests.filter((r) => r.path.endsWith("/probe")).length;
    // Another page listing the computers (Model & API choosing where Tasks run) checks nothing.
    t.watch<DevicesValue>({ topic: "devices" });
    await t.time.pass(100);
    expect(probes()).toBe(0);
    const shown = t.watch<DevicesValue>({ topic: "devices", visit: "1" });
    await t.time.pass(100);
    expect(probes()).toBe(2);
    expect(shown().checks).toEqual({ a: "pending", b: "pending", c: "pending" });
    releases.shift()!();
    await t.time.pass(100);
    expect(probes()).toBe(3);
    // A's check answered after the last read started: the read's older readiness does not undo it.
    expect(
      shown().devices.find((d) => d.device_id === "a")?.device_runtimes[0]?.fresh
    ).toBe(true);
    await t.time.pass(15_000, 1_000);
    expect(
      shown().devices.find((d) => d.device_id === "a")?.device_runtimes[0]?.fresh
    ).toBe(false);
    // Not checked again in this visit; a new visit checks again.
    expect(probes()).toBe(3);
    for (const release of releases.splice(0)) release();
    await t.time.pass(100);
    t.watch<DevicesValue>({ topic: "devices", visit: "2" });
    await t.time.pass(100);
    expect(probes()).toBeGreaterThan(3);
  });

  it("says a failed check, checks again on request, and lands a page asked for during a check without undoing it", async () => {
    const t = setup();
    t.api.on("GET", list, (request) =>
      json(
        200,
        request.path.includes("cursor=page_2")
          ? { devices: [device("next", null)], next_cursor: null }
          : { devices: [device("a", t.seconds() - 1)], next_cursor: "page_2" }
      )
    );
    let probes = 0;
    let release!: () => void;
    t.api.on("POST", `${list}/a/probe`, async () => {
      probes += 1;
      if (probes === 1) return json(503, { error: "unavailable" });
      await new Promise<void>((resolve) => (release = resolve));
      return json(200, device("a", t.seconds() + 600));
    });
    const shown = t.watch<DevicesValue>({ topic: "devices", visit: "1" });
    await t.time.pass(100);
    expect(shown().checks).toEqual({ a: "failed" });
    expect(probes).toBe(1);

    const again = t.client.call("devices.check", { device: "a" });
    await t.time.pass(100);
    await again;
    expect(probes).toBe(2);
    expect(shown().checks).toEqual({ a: "pending" });
    // The next page is asked for while the check runs, and answers after it.
    const page = t.api.hold("GET", list);
    const more = t.client.call("devices.more", {});
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    expect(shown().checks).toEqual({});
    page();
    await t.time.pass(100);
    await more;
    expect(
      shown().devices.map((d) => [d.device_id, d.device_runtimes[0]?.fresh])
    ).toEqual([
      ["a", true],
      ["next", undefined],
    ]);
    expect(shown().hasMore).toBe(false);
    expect(t.api.requests.filter((r) => r.path.includes("cursor="))).toHaveLength(1);
  });

  it("shows the Cloud VM apart from the computers, from the first page only, and checks it on entry", async () => {
    const t = setup();
    let cloud: unknown = device("vm", t.seconds() - 1, { name: "Cloud Workspace" });
    t.api.on("GET", list, (request) =>
      json(
        200,
        request.path.includes("cursor=page_2")
          ? { devices: [device("next", null)], cloud_vm: null, next_cursor: null }
          : { devices: [device("mac", null)], cloud_vm: cloud, next_cursor: "page_2" }
      )
    );
    t.api.on("POST", `${list}/vm/probe`, () =>
      json(200, device("vm", t.seconds() + 600))
    );
    const shown = t.watch<DevicesValue>({ topic: "devices", visit: "1" });
    await t.time.pass(100);
    expect(shown().devices.map((d) => d.device_id)).toEqual(["mac"]);
    expect(t.api.seen("POST", `${list}/vm/probe`)).toHaveLength(1);
    expect(shown().cloud?.device_runtimes[0]?.fresh).toBe(true);

    const more = t.client.call("devices.more", {});
    await t.time.pass(100);
    await more;
    expect(shown().devices.map((d) => d.device_id)).toEqual(["mac", "next"]);
    expect(shown().cloud?.device_id).toBe("vm");

    cloud = null;
    const refresh = t.client.call("devices.refresh", {});
    await t.time.pass(100);
    await refresh;
    expect(shown().cloud).toBeNull();
  });

  it("reads this computer by its id wherever it falls, and changes access, names and removals", async () => {
    const t = setup();
    let rows: Record<string, unknown>[] = [
      device("a", null, {
        access: "read",
        station_id: "st_a",
        tasks_readiness: "ready",
        task_models: { codex: ["gpt-5.5"] },
      }),
    ];
    t.api.on("GET", list, () => json(200, { devices: rows, next_cursor: null }));
    t.api.on("GET", `${list}/mine`, device("mine", null, { name: "This Mac" }));
    t.api.on("PUT", `${list}/a/access`, () => {
      rows = [{ ...rows[0]!, access: "off", allows_operations: false }];
      return json(200, { access: "off", allows_operations: false });
    });
    t.api.on("DELETE", `${list}/a`, () => {
      rows = [];
      return json(200, { removed: true });
    });
    const shown = t.watch<DevicesValue>({
      topic: "devices",
      local: "mine",
      visit: "1",
    });
    await t.time.pass(100);
    expect(shown().devices.map((d) => d.device_id)).toEqual(["a", "mine"]);
    expect(shown().devices[0]).toMatchObject({
      access: "read",
      station_id: "st_a",
      tasks_readiness: "ready",
      task_models: { codex: ["gpt-5.5"] },
    });
    const access = t.client.call("devices.setAccess", {
      workspace: WS,
      device: "a",
      access: "off",
    });
    await t.time.pass(100);
    expect(await access).toBe("off");
    expect(t.api.seen("PUT", `${list}/a/access`)[0]!.body).toEqual({ access: "off" });
    expect(shown().devices[0]).toMatchObject({
      access: "off",
      allows_operations: false,
    });
    const removed = t.client.call("devices.remove", { workspace: WS, device: "a" });
    await t.time.pass(100);
    await removed;
    expect(shown().devices.map((d) => d.device_id)).toEqual(["mine"]);
  });
});

describe("adding a computer", () => {
  it("gives the one-time station install command for the workspace", async () => {
    const t = setup();
    t.api.on("POST", `/v1/comma/workspaces/${WS}/stations/enrollments`, {
      token: "tok",
      command: "curl -fsSL https://api.comma.test/stations/install.sh | sh -s -- tok",
      expires_at: 1_900_000_000,
    });
    const enrolled = t.client.call("devices.enroll", { workspace: WS });
    await t.time.pass(100);
    expect(await enrolled).toEqual({
      command: "curl -fsSL https://api.comma.test/stations/install.sh | sh -s -- tok",
      expiresAt: 1_900_000_000,
    });
  });
});

describe("a phone's Comma devices", () => {
  const nearby = `/v1/comma/workspaces/${WS}/nearby-devices`;
  const offer = {
    offer_id: "off_1",
    name: "Kitchen",
    model: "t-circle",
    short_id: "5d28",
    reporter_device_id: "phone-1",
    status: "open",
    expires_at: 1_900_000_000,
    revision: 2,
  };
  const shown = {
    offerId: "off_1",
    name: "Kitchen",
    model: "t-circle",
    shortId: "5D28",
    reporterDeviceId: "phone-1",
    status: "open",
    expiresAt: 1_900_000_000,
    revision: 2,
  };

  it("reports a device found nearby and answers whether the server offers it", async () => {
    const t = setup();
    t.api.on("POST", nearby, {
      devices: [
        { short_id: "5d28", outcome: "offered" },
        { short_id: "0000", outcome: "rejected" },
      ],
    });
    const report = (shortId: string) =>
      t.client.call("devices.reportNearby", {
        workspace: WS,
        reporter: "phone-1",
        request: "req-1",
        device: {
          name: "Comma-5D28",
          model: "t-circle",
          state: "unprovisioned",
          shortId,
          rssi: -50,
        },
      });
    const offered = report("5D28");
    const refused = report("0000");
    await t.time.pass(100);
    expect(await offered).toBe(true);
    expect(await refused).toBe(false);
    expect(t.api.seen("POST", nearby)[0]!.body).toEqual({
      request_id: "req-1",
      reporter_device_id: "phone-1",
      devices: [
        {
          name: "Comma-5D28",
          model: "t-circle",
          state: "unprovisioned",
          short_id: "5D28",
          rssi: -50,
        },
      ],
    });
  });

  it("acts on a setup offer, and answers one that moved on as it is now", async () => {
    const t = setup();
    const path = `${nearby}/offers/off_1`;
    t.api.on("POST", path, () => json(409, { error: "offer_closed" }));
    t.api.on("GET", path, { offer: { ...offer, status: "done", revision: 3 } });
    const dismissed = t.client.call("devices.actOnSetupOffer", {
      workspace: WS,
      offer: "off_1",
      action: "dismiss",
    });
    await t.time.pass(100);
    expect(await dismissed).toEqual({ ...shown, status: "done", revision: 3 });
    expect(t.api.seen("POST", path)[0]!.body).toEqual({ action: "dismiss" });

    // Naming the device set up for it, a refusal is the caller's to say.
    const attached = t.client.call("devices.actOnSetupOffer", {
      workspace: WS,
      offer: "off_1",
      action: "started",
      device: "dev_1",
    });
    const refused = expect(attached).rejects.toMatchObject({
      code: "offer_closed",
      status: 409,
    });
    await t.time.pass(100);
    await refused;
    expect(t.api.seen("POST", path)[1]!.body).toEqual({
      action: "started",
      device_id: "dev_1",
    });

    t.api.on("POST", path, { offer });
    const started = t.client.call("devices.actOnSetupOffer", {
      workspace: WS,
      offer: "off_1",
      action: "started",
    });
    await t.time.pass(100);
    expect(await started).toEqual(shown);
  });

  it("reads one device now, none while the workspace has not seen it, and says what access a device took", async () => {
    const t = setup();
    t.api.on("GET", `${list}/dev_1`, device("dev_1", null));
    t.api.on("GET", `${list}/dev_2`, () => json(404, { error: "not_found" }));
    t.api.on("PUT", `${list}/dev_1/access`, { allows_operations: true });
    t.api.on("GET", list, { devices: [], next_cursor: null });
    const one = t.client.call("devices.get", { workspace: WS, device: "dev_1" });
    const none = t.client.call("devices.get", { workspace: WS, device: "dev_2" });
    const access = t.client.call("devices.setAccess", {
      workspace: WS,
      device: "dev_1",
      access: "full",
    });
    await t.time.pass(100);
    expect(await one).toMatchObject({ device_id: "dev_1" });
    expect(await none).toBeNull();
    // A server from before answers the permission alone.
    expect(await access).toBe("full");
  });
});

describe("Settings › Devices, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", list, () =>
      json(200, { devices: [device("a", t.seconds() + 20)], next_cursor: null })
    );
    t.watch({ topic: "devices", visit: "1" });
    await t.time.pass(31_000, 1_000);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(list)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(
      new TextEncoder().encode(body.replace('"name":"a"', '"name":"renamed"'))
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
