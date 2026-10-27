import { describe, expect, it } from "vitest";
import {
  SetupFlow,
  type SetupEffect,
  type SetupEvent,
} from "../src/device-setup/flow.ts";
import {
  advertisement,
  credentialsJson,
  WifiPages,
  type Credentials,
} from "../src/device-setup/protocol.ts";

const credentials: Credentials = {
  deviceId: "dev1",
  connectorToken: "salix_conn_test",
  voiceKeyId: "key1",
  voiceKey: "salix_vk_test",
  connectUrl: "wss://connect.test/v1/connect",
  voiceServer: "https://voice.test",
  voiceGroup: "group",
  offerUpdated: false,
};
const board = { id: "session-only", name: "Comma-6AD8", rssi: -50 };
const network = { ssid: "Home", rssi: -40, secure: true };
function setup() {
  const flow = new SetupFlow();
  flow.start();
  const send = (e: SetupEvent) => flow.handle(e);
  send({ type: "found", device: board });
  send({ type: "pick", id: board.id });
  send({ type: "connected" });
  send({ type: "paired", name: board.name });
  send({ type: "networks", networks: [network] });
  return { flow, send };
}
function mint() {
  const t = setup();
  t.send({ type: "join", ssid: "Home", password: "12345678" });
  const effects = t.send({
    type: "status",
    status: { state: "wifi_up", ssid: "Home" },
  });
  const attempt = (effects[0] as Extract<SetupEffect, { type: "mint" }>).attempt;
  t.send({ type: "minted", credentials, attempt });
  return { ...t, attempt };
}
describe("Apple device setup flow", () => {
  it("mints only after the selected Wi-Fi joins, persists before writing, and confirms only after online", () => {
    const t = setup();
    expect(
      t.send({ type: "join", ssid: "Home", password: "12345678" }).map((e) => e.type)
    ).toEqual(["join", "arm"]);
    expect(
      t.send({ type: "status", status: { state: "wifi_up", ssid: "Old" } })
    ).toEqual([]);
    expect(
      t.send({ type: "status", status: { state: "wifi_up", ssid: "Home" } })
    ).toEqual([{ type: "mint", name: board.name, attempt: 1 }]);
    expect(
      t.send({ type: "minted", credentials, attempt: 1 }).map((e) => e.type)
    ).toEqual(["remember"]);
    expect(t.send({ type: "remembered", attempt: 1 }).map((e) => e.type)).toEqual([
      "write",
      "arm",
    ]);
    expect(
      t.send({ type: "status", status: { state: "saved" } }).map((e) => e.type)
    ).toEqual(["watch", "arm"]);
    expect(t.send({ type: "online" }).map((e) => e.type)).toContain("confirm");
    expect(t.flow.state).toEqual({
      step: "done",
      name: board.name,
      deviceId: "dev1",
      online: true,
    });
  });
  it("returns to Wi-Fi on a wrong password without minting", () => {
    const t = setup();
    t.send({ type: "join", ssid: "Home", password: "12345678" });
    expect(
      t.send({
        type: "status",
        status: { state: "wifi_failed", error: "wrong_password" },
      })
    ).toEqual([]);
    expect(t.flow.state).toMatchObject({ step: "wifi", failure: "wrong_password" });
  });
  it("revokes late credentials after cancellation and ignores late persistence", () => {
    const t = mint();
    expect(t.send({ type: "cancel" })).toContainEqual({ type: "revoke", credentials });
    expect(t.send({ type: "remembered", attempt: t.attempt })).toEqual([]);
    expect(t.send({ type: "minted", credentials, attempt: t.attempt })).toEqual([
      { type: "revoke", credentials },
    ]);
  });
  it("revokes when storage fails and when the link drops during minting", () => {
    for (const event of [
      { type: "failed", problem: "storage" },
      { type: "lost" },
    ] as SetupEvent[]) {
      const t = mint();
      expect(t.send(event)).toContainEqual({ type: "revoke", credentials });
    }
  });
  it("keeps an uncertain write for reconciliation and revokes a rejected connector", () => {
    const t = mint();
    t.send({ type: "remembered", attempt: t.attempt });
    expect(t.send({ type: "lost" }).map((e) => e.type)).toEqual(["watch", "arm"]);
    expect(t.send({ type: "cancel" }).map((e) => e.type)).not.toContain("revoke");
    const rejected = mint();
    rejected.send({ type: "remembered", attempt: rejected.attempt });
    rejected.send({ type: "status", status: { state: "saved" } });
    expect(
      rejected.send({ type: "status", status: { state: "connector_failed" } })
    ).toContainEqual({ type: "revoke", credentials });
  });
  it("ignores a timer from the previous step", () => {
    const t = setup();
    expect(t.send({ type: "timeout", timer: "connect", generation: 2 })).toEqual([]);
    expect(t.flow.state.step).toBe("wifi");
  });
});
describe("firmware codecs", () => {
  it("decodes the Apple company prefix without inventing a board model", () => {
    expect(advertisement([255, 255, 1, 1, 1, 0x6a, 0xd8])).toEqual({
      name: "Comma-6AD8",
      state: "pairing",
    });
    expect(advertisement([1, 1, 1, 0x6a, 0xd8])).toBeNull();
  });
  it("collects out-of-order pages and keeps the strongest AP", () => {
    const pages = new WifiPages();
    expect(pages.accept({ page: 1, pages: 2, aps: [network] })).toBeNull();
    expect(
      pages.accept({ page: 0, pages: 2, aps: [{ ...network, rssi: -80 }] })
    ).toEqual([network]);
    expect(pages.accept({ error: "busy" })).toBe("failed");
  });
  it("uses the connector URL verbatim and bounds UTF-8 writes", () => {
    expect(JSON.parse(credentialsJson(credentials, "wsp", "Kitchen")).connect_url).toBe(
      credentials.connectUrl
    );
    expect(() => credentialsJson(credentials, "wsp", "中".repeat(22))).toThrow();
    expect(() =>
      credentialsJson(
        {
          ...credentials,
          connectorToken: "salix_conn_" + "a".repeat(145),
          voiceKey: "salix_vk_" + "b".repeat(145),
        },
        "w".repeat(90),
        "Kitchen"
      )
    ).toThrow("512");
  });
});

const expire = (flow: SetupFlow, effects: SetupEffect[]) => {
  const arm = effects.find((e) => e.type === "arm") as Extract<
    SetupEffect,
    { type: "arm" }
  >;
  return flow.handle({
    type: "timeout",
    timer: arm.timer,
    generation: arm.generation,
  });
};

describe("setup timeout and retry boundaries from Android", () => {
  it("revokes uncertain credentials after the online budget, but preserves an acknowledged save", () => {
    const uncertain = mint();
    uncertain.send({ type: "remembered", attempt: uncertain.attempt });
    expect(expire(uncertain.flow, uncertain.send({ type: "lost" }))).toContainEqual({
      type: "revoke",
      credentials,
    });
    const saved = mint();
    saved.send({ type: "remembered", attempt: saved.attempt });
    const effects = expire(
      saved.flow,
      saved.send({ type: "status", status: { state: "saved" } })
    );
    expect(effects.map((e) => e.type)).not.toContain("revoke");
    expect(effects).toContainEqual({ type: "confirm", deviceId: credentials.deviceId });
    expect(saved.flow.state).toMatchObject({ step: "done", online: false });
  });
  it("treats a save timeout as uncertain and rejects a failed save", () => {
    const t = mint();
    const saving = t.send({ type: "remembered", attempt: t.attempt });
    expect(expire(t.flow, saving).map((e) => e.type)).toEqual(["watch", "arm"]);
    const failed = mint();
    failed.send({ type: "remembered", attempt: failed.attempt });
    expect(
      failed.send({
        type: "status",
        status: { state: "wifi_up", error: "save_failed" },
      })
    ).toContainEqual({ type: "revoke", credentials });
  });
  it("does not reuse a late mint when the user retries", () => {
    const t = setup();
    t.send({ type: "join", ssid: "Home", password: "12345678" });
    t.send({ type: "status", status: { state: "wifi_up" } });
    t.send({ type: "lost" });
    t.send({ type: "retry" });
    t.send({ type: "found", device: board });
    t.send({ type: "pick", id: board.id });
    t.send({ type: "connected" });
    t.send({ type: "paired", name: board.name });
    t.send({ type: "networks", networks: [network] });
    t.send({ type: "join", ssid: "Home", password: "12345678" });
    t.send({ type: "status", status: { state: "wifi_up" } });
    expect(t.send({ type: "failed", problem: "server", attempt: 1 })).toEqual([]);
    expect(t.send({ type: "minted", credentials, attempt: 1 })).toEqual([
      { type: "revoke", credentials },
    ]);
    expect(
      t.send({ type: "minted", credentials, attempt: 2 }).map((e) => e.type)
    ).toEqual(["remember"]);
  });
  it("shows one result per name, explains a quiet scan, and bounds found devices", () => {
    const flow = new SetupFlow();
    const scanning = flow.start();
    flow.handle({ type: "found", device: board });
    flow.handle({ type: "found", device: { ...board, id: "new-session" } });
    expire(flow, scanning);
    expect(flow.state).toMatchObject({
      step: "scanning",
      quiet: true,
      devices: [{ ...board, id: "new-session" }],
    });
    for (let i = 0; i < 60; i++)
      flow.handle({
        type: "found",
        device: { ...board, id: String(i), name: String(i) },
      });
    expect(flow.state.step === "scanning" && flow.state.devices.length).toBe(50);
  });
  it("offers another Wi-Fi scan after a failed scan and rejects invalid names and passwords", () => {
    const t = setup();
    t.send({ type: "scanFailed" });
    expect(t.send({ type: "rescan" }).map((e) => e.type)).toEqual(["scanWifi", "arm"]);
    t.send({ type: "rename", name: "中".repeat(22) });
    expect(t.flow.state).toMatchObject({ name: board.name });
    expect(t.send({ type: "join", ssid: "Home", password: "short" })).toEqual([]);
  });
});
