import { CoreClient } from "@comma/core-kernel/client";
import { Effect } from "effect";
import { expect, it } from "vitest";
import type { DeviceSetupPort } from "../src/host.ts";
import type { SetupValue } from "../src/device-setup/controller.ts";
import { gatt } from "../src/device-setup/protocol.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

class Ble implements DeviceSetupPort {
  readonly records = new Map<string, Record<string, unknown>>();
  readonly writes: Record<string, unknown>[] = [];
  private events: unknown[] = [];
  private waiting: ((e: unknown) => void) | null = null;
  emit(e: unknown) {
    if (this.waiting) {
      const callback = this.waiting;
      this.waiting = null;
      callback(e);
    } else this.events.push(e);
  }
  call: DeviceSetupPort["call"] = (op, p) => {
    if (op === "next")
      return Effect.callback((resume) => {
        if (this.events.length) resume(Effect.succeed(this.events.shift()));
        else this.waiting = (value) => resume(Effect.succeed(value));
        return Effect.sync(() => {
          this.waiting = null;
        });
      });
    return Effect.sync(() => {
      if (op === "read")
        return JSON.stringify({
          mac: "aa:bb:cc:dd:6a:d8",
          name: "Comma-6AD8",
          provisioned: false,
        });
      if (op === "write") {
        if (p.characteristic === gatt.credentials) expect(this.records.size).toBe(1);
        this.writes.push(p);
      }
      if (op === "put") {
        const r = p.record as Record<string, unknown>;
        this.records.set(String(r.deviceId), r);
      }
      if (op === "remove") this.records.delete(String(p.deviceId));
      if (op === "records")
        return [...this.records.values()].filter(
          (r) =>
            (!p.deviceId || r.deviceId === p.deviceId) && (!p.pending || !r.confirmed)
        );
      return null;
    });
  };
}
class SetupHost extends FakeHost {
  readonly deviceSetup = new Ble();
}
function setup() {
  const host = new SetupHost();
  const core = startTestCore(host, { replays: false });
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  let value: SetupValue | undefined;
  client.subscribe(
    { topic: "deviceSetup" },
    (v) => {
      value = v as SetupValue;
    },
    () => {}
  );
  const api = host.api;
  const base = "/v1/comma/workspaces/wsp";
  api.on("POST", `${base}/connector-token`, {
    token: "salix_conn_test",
    server: "wss://salix.test",
    device_id: "dev1",
    connect_url: "wss://salix.test/v1/connect",
  });
  api.on("POST", `${base}/voice-api-keys`, {
    key_id: "key1",
    name: "Comma-6AD8 (dev1)",
    prefix: "salix_vk",
    status: "active",
    key: "salix_vk_test",
    sessions_url: "wss://salix.test/v1/agent-groups/g/sessions",
    readiness_url: "https://salix.test/v1/agent-groups/g/voice",
  });
  api.on("DELETE", `${base}/connector-token`, { revoked: true });
  api.on("DELETE", `${base}/voice-api-keys/key1`, {});
  const pass = () => host.time!.pass(100);
  const call = async (name: string, params: object) => {
    const done = client.call(name, params);
    await pass();
    return done;
  };
  const emit = async (event: unknown) => {
    host.deviceSetup.emit(event);
    await pass();
  };
  const status = (state: string, extra: object = {}) =>
    emit({
      type: "value",
      characteristic: gatt.status,
      value: JSON.stringify({ state, ...extra }),
    });
  const start = async () => {
    await call("deviceSetup.start", { workspace: "wsp" });
    await emit({
      type: "found",
      peripheral: "transient",
      manufacturer: [255, 255, 1, 1, 0, 106, 216],
      rssi: -50,
    });
    await call("deviceSetup.event", { type: "pick", id: "transient" });
    await emit({
      type: "value",
      characteristic: gatt.wifiScan,
      value: JSON.stringify({
        page: 0,
        pages: 1,
        aps: [{ ssid: "Home", rssi: -40, secure: true }],
      }),
    });
    await call("deviceSetup.event", {
      type: "join",
      ssid: "Home",
      password: "12345678",
    });
  };
  return {
    host,
    api,
    client,
    base,
    call,
    emit,
    status,
    start,
    pass,
    value: () => value!,
  };
}
it("runs setup through the core host, persists before writing, and keeps secrets out of the topic", async () => {
  const t = setup();
  await t.start();
  expect(t.api.seen("POST", `${t.base}/connector-token`)).toHaveLength(0);
  await t.status("wifi_up", { ssid: "Home" });
  expect(
    t.host.deviceSetup.writes.some((w) => w.characteristic === gatt.credentials)
  ).toBe(true);
  t.api.on("GET", `${t.base}/devices/dev1`, {
    device_id: "dev1",
    name: "Comma-6AD8",
    status: "connected",
    allows_operations: true,
    device_runtimes: [],
  });
  t.api.on("PUT", `${t.base}/devices/dev1`, {
    device_id: "dev1",
    name: "Comma-6AD8",
    status: "connected",
    allows_operations: true,
    device_runtimes: [],
  });
  await t.status("saved");
  expect(t.value().state.step).toBe("done");
  expect(t.host.deviceSetup.records.get("dev1")?.confirmed).toBe(true);
  expect(JSON.stringify(t.value())).not.toMatch(/salix_conn_|salix_vk_|12345678/);
});
it("returns on wrong Wi-Fi password and fails on a lost link without creating credentials", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_failed", { error: "wrong_password" });
  expect(t.value().state).toMatchObject({ step: "wifi", failure: "wrong_password" });
  await t.emit({ type: "lost" });
  expect(t.value().state).toEqual({ step: "failed", problem: "disconnected" });
  expect(t.api.seen("POST", `${t.base}/connector-token`)).toHaveLength(0);
});
it("waits for current connectivity before reporting a previously seen device online", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_up", { ssid: "Home" });
  const device = {
    device_id: "dev1",
    name: "Comma-6AD8",
    status: "disconnected",
    allows_operations: true,
    device_runtimes: [],
    system_info: { client_source: "esp32-devkit" },
  };
  t.api.on("GET", `${t.base}/devices/dev1`, device);
  await t.status("saved");
  expect(t.value().state).toMatchObject({ step: "setup", phase: "online" });
  t.api.on("GET", `${t.base}/devices/dev1`, { ...device, status: "connected" });
  await t.host.time!.pass(2_000);
  expect(t.value().state).toMatchObject({ step: "done", online: true });
});
it("revokes both credentials when cancelled after minting", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_up", { ssid: "Home" });
  await t.call("deviceSetup.event", { type: "cancel" });
  expect(t.api.seen("DELETE", `${t.base}/connector-token`)).toHaveLength(1);
  expect(t.api.seen("DELETE", `${t.base}/voice-api-keys/key1`)).toHaveLength(1);
  expect(t.host.deviceSetup.records.size).toBe(0);
});
it("reconciles an unconfirmed write on the next device list read", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_up", { ssid: "Home" });
  await t.status("saved");
  await t.call("deviceSetup.event", { type: "cancel" });
  t.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp", group_id: "g", name: "Main" }],
  });
  t.api.on("GET", `${t.base}/devices`, { devices: [], next_cursor: null });
  t.api.on("GET", `${t.base}/devices/dev1`, {
    device_id: "dev1",
    name: "Comma-6AD8",
    status: "disconnected",
    allows_operations: true,
    device_runtimes: [],
    system_info: { client_source: "esp32-devkit" },
  });
  t.client.subscribe(
    { topic: "devices" },
    () => {},
    () => {}
  );
  await t.pass();
  expect(t.host.deviceSetup.records.get("dev1")?.confirmed).toBe(true);
});

it("keeps the credentials of a device that saved them but has not come online", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_up", { ssid: "Home" });
  t.api.on("GET", `${t.base}/devices/dev1`, {
    device_id: "dev1",
    name: "Comma-6AD8",
    status: "disconnected",
    allows_operations: true,
    device_runtimes: [],
  });
  await t.status("saved");
  await t.host.time!.pass(91_000);
  expect(t.value().state).toMatchObject({ step: "done", online: false });
  await t.host.time!.pass(16 * 60_000);
  t.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp", group_id: "g", name: "Main" }],
  });
  t.api.on("GET", `${t.base}/devices`, { devices: [], next_cursor: null });
  t.client.subscribe(
    { topic: "devices" },
    () => {},
    () => {}
  );
  await t.pass();
  expect(t.api.seen("DELETE", `${t.base}/connector-token`)).toHaveLength(0);
  expect(t.host.deviceSetup.records.get("dev1")?.confirmed).toBe(true);
});

it("retries cancelled revocation even when the device later appears online", async () => {
  const t = setup();
  await t.start();
  await t.status("wifi_up", { ssid: "Home" });
  t.api.on("DELETE", `${t.base}/connector-token`, () =>
    json(503, { error: "unavailable" })
  );
  await t.call("deviceSetup.event", { type: "cancel" });
  expect(t.host.deviceSetup.records.get("dev1")?.revoking).toBe(true);
  t.api.on("DELETE", `${t.base}/connector-token`, { revoked: true });
  t.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp", group_id: "g", name: "Main" }],
  });
  t.api.on("GET", `${t.base}/devices`, { devices: [], next_cursor: null });
  t.api.on("GET", `${t.base}/devices/dev1`, {
    device_id: "dev1",
    name: "Board",
    status: "connected",
    allows_operations: true,
    device_runtimes: [],
  });
  t.client.subscribe(
    { topic: "devices" },
    () => {},
    () => {}
  );
  await t.pass();
  expect(t.api.seen("DELETE", `${t.base}/connector-token`)).toHaveLength(2);
  expect(t.host.deviceSetup.records.size).toBe(0);
});

it("removes a Comma device through the core when this host has no Bluetooth port", async () => {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  const base = "/v1/comma/workspaces/wsp";
  host.api.on("GET", `${base}/voice-api-keys`, []);
  host.api.on("DELETE", `${base}/devices/dev1`, {});
  const removed = client.call("deviceSetup.remove", {
    workspace: "wsp",
    device: "dev1",
  });
  await host.time!.pass(100);
  await removed;
  expect(host.api.seen("DELETE", `${base}/devices/dev1`)).toHaveLength(1);
});
