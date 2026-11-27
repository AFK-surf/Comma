import { CoreClient, topicKey } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { LocationSharingValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const ensureHome = "/v1/comma/groups/g/assistant-chat";
const messages = "/v1/comma/groups/g/conversations/home/messages";
const home = {
  group_id: "g",
  id: "home",
  kind: "user_chat",
  title: "Home",
  status: "active",
};
const readAt = Date.UTC(2026, 10, 12, 3, 0, 0);
const tokyo = { latitude: 35.6812, longitude: 139.7671, accuracy: 25, readAt };

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", "/v1/comma/groups/g/conversations", { data: [] });
  host.api.onStream("/v1/comma/groups/g/conversations/events");
  host.api.on("POST", ensureHome, home);
  host.api.on("POST", messages, json(202, { ...home, accepted_message_id: "m-new" }));
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const sharing = { topic: "locationSharing" } as const;
  client.subscribe(
    sharing,
    (v) => values.set(topicKey(sharing), v),
    () => undefined
  );
  core.observeSession(signedIn());
  let sent = 0;
  const send = async () => {
    const id = `0b8f2c4e-4f1a-4c6d-9b7e-2a1d3c5e7f9${sent++}`;
    const answer = client.call("quickChat.sendMessage", {
      client_request_id: id,
      text: "Lunch nearby?",
    });
    await host.time!.pass(100);
    await answer;
    const bodies = host.api
      .seen("POST", messages)
      .map((r) => r.body as Record<string, unknown>);
    return bodies[bodies.length - 1]!;
  };
  return {
    host,
    client,
    send,
    enabled: () =>
      (values.get(topicKey(sharing)) as LocationSharingValue | undefined)?.enabled,
  };
}

describe("location sharing", () => {
  it("is off until the person turns it on, and a position given meanwhile goes nowhere", async () => {
    const t = setup();
    await t.host.time!.pass(100);
    expect(t.enabled()).toBe(false);
    await t.client.call("locationSharing.report", { position: tokyo });
    expect(await t.send()).not.toHaveProperty("client_location");
  });

  it("sends the phone's newest position with each message while on, and forgets it when turned off", async () => {
    const t = setup();
    await t.client.call("locationSharing.set", { enabled: true });
    await t.host.time!.pass(100);
    expect(t.enabled()).toBe(true);
    // Turned on, but the phone has not read a position yet.
    expect(await t.send()).not.toHaveProperty("client_location");

    await t.client.call("locationSharing.report", { position: tokyo });
    expect((await t.send()).client_location).toEqual({
      latitude: 35.6812,
      longitude: 139.7671,
      accuracy_m: 25,
      read_at: "2026-11-12T03:00:00.000Z",
    });

    // The app left the front: the position goes with no later message.
    await t.client.call("locationSharing.report", { position: null });
    expect(await t.send()).not.toHaveProperty("client_location");

    await t.client.call("locationSharing.report", { position: tokyo });
    await t.client.call("locationSharing.set", { enabled: false });
    await t.host.time!.pass(100);
    expect(t.enabled()).toBe(false);
    expect(await t.send()).not.toHaveProperty("client_location");
    // Turned on again, the old position is not brought back.
    await t.client.call("locationSharing.set", { enabled: true });
    expect(await t.send()).not.toHaveProperty("client_location");
  });

  it("refuses a position outside the globe", async () => {
    const t = setup();
    await t.client.call("locationSharing.set", { enabled: true });
    await t.host.time!.pass(100);
    await expect(
      t.client.call("locationSharing.report", { position: { ...tokyo, latitude: 91 } })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });
});
