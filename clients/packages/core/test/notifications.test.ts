import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn("user-1", { sessionId: "session-1" }));
  host.api.on("GET", "/v1/comma/auth/session", { session_id: "session-1" });
  return { host, client, time: host.time!, api: host.api };
}

const device = {
  token: "apns-token",
  environment: "production",
  workspace: "w1",
  group: "g1",
  bundleId: "surf.comma.ios",
  locale: "en-US",
};

describe("the iPhone's push registrations", () => {
  it("registers the device for the session signed in, as the server takes it", async () => {
    const t = setup();
    t.api.on(
      "POST",
      "/v1/comma/notifications/devices",
      json(200, { id: "reg-1", status: "active" })
    );
    const registered = t.client.call("notifications.registerDevice", {
      ...device,
      session: "session-1",
    });
    await t.time.pass(100);
    await expect(registered).resolves.toEqual({ id: "reg-1" });
    expect(t.api.seen("POST", "/v1/comma/notifications/devices")[0]!.body).toEqual({
      token: "apns-token",
      environment: "production",
      workspace_id: "w1",
      group_id: "g1",
      bundle_id: "surf.comma.ios",
      locale: "en-US",
    });
  });

  it("refuses a registration for a session that is no longer the one signed in, asking nothing", async () => {
    const t = setup();
    const refused = expect(
      t.client.call("notifications.registerDevice", { ...device, session: "session-0" })
    ).rejects.toMatchObject({ code: "session_changed" });
    await t.time.pass(100);
    await refused;
    expect(t.api.seen("POST", "/v1/comma/notifications/devices")).toEqual([]);
  });

  it("registers a Live Activity's token, or the push-to-start token when it names no activity", async () => {
    const t = setup();
    for (const path of ["live-activities", "push-to-start"])
      t.api.on("POST", `/v1/comma/notifications/${path}`, (request) =>
        json(200, {
          id: (request.body as { registration_id: string }).registration_id,
          status: "active",
        })
      );
    const live = t.client.call("notifications.registerActivity", {
      ...device,
      session: "session-1",
      registration: "reg-live",
      activity: "activity-1",
    });
    const start = t.client.call("notifications.registerActivity", {
      ...device,
      session: "session-1",
      registration: "reg-start",
    });
    await t.time.pass(100);
    await expect(live).resolves.toEqual({ id: "reg-live" });
    await expect(start).resolves.toEqual({ id: "reg-start" });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/live-activities")[0]!.body
    ).toMatchObject({
      registration_id: "reg-live",
      activity_id: "activity-1",
      activity_schema: "tasks_v1",
    });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/push-to-start")[0]!.body
    ).toMatchObject({
      registration_id: "reg-start",
      activity_schema: "tasks_v1",
      group_id: "g1",
    });
  });

  it("fails a registration the server did not make active", async () => {
    const t = setup();
    t.api.on(
      "POST",
      "/v1/comma/notifications/devices",
      json(200, { id: "reg-1", status: "pending" })
    );
    const refused = expect(
      t.client.call("notifications.registerDevice", { ...device, session: "session-1" })
    ).rejects.toMatchObject({ code: "bad_response" });
    await t.time.pass(100);
    await refused;
  });
});
