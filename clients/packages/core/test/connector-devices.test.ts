import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const tokens = "/v1/comma/workspaces/wsp/connector-token";
const keys = "/v1/comma/workspaces/wsp/voice-api-keys";
const offer = "/v1/comma/workspaces/wsp/nearby-devices/offers/off_1";

/** The session `signedIn()` gives the core, as the app names it. */
const lease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "authority-1",
  generation: 1,
  sessionId: "session-user-1",
};

const token = {
  token: "salix_conn_test",
  server: "wss://salix.test",
  device_id: "dev_1",
  connect_url: "wss://connect.test/v1/connect",
};
const key = {
  key_id: "gak_1",
  name: "Kitchen (dev_1)",
  prefix: "salix_vk",
  status: "active",
  key: "salix_vk_secret",
  sessions_url: "wss://voice.test/v1/agent-groups/grp_1/sessions",
  readiness_url: "https://voice.test/v1/agent-groups/grp_1/voice",
};

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  // The app's own channel: it may make the calls that answer credentials.
  const client = new CoreClient(
    inProcessOpener(core, host, undefined, { host: true }),
    {
      schedule: () => undefined,
    }
  );
  core.observeSession(signedIn());
  const call = async (
    name: "connector.provisionDevice" | "connector.unprovisionDevice",
    params: object
  ) => {
    const done = client
      .call(name, { workspaceId: "wsp", lease, ...params } as never)
      .then(
        (value) => ({ value }),
        (error: { code: string; status?: number }) => ({ error })
      );
    await host.time!.pass(100);
    return done;
  };
  return { api: host.api, call };
}

describe("a Comma device's credentials", () => {
  it("are a Connector token and a voice key named after the device, and its setup offer is told", async () => {
    const t = setup();
    t.api.on("POST", tokens, token);
    t.api.on("POST", keys, () => json(201, key));
    t.api.on("POST", offer, { offer: {} });
    expect(
      await t.call("connector.provisionDevice", { name: "Kitchen", offer: "off_1" })
    ).toEqual({
      value: {
        deviceId: "dev_1",
        connectorToken: "salix_conn_test",
        connectUrl: "wss://connect.test/v1/connect",
        voiceKeyId: "gak_1",
        voiceKey: "salix_vk_secret",
        voiceServer: "https://voice.test",
        voiceGroup: "grp_1",
        offerUpdated: true,
      },
    });
    expect(t.api.seen("POST", tokens)[0]!.body).toEqual({
      name: "Kitchen",
      registration_expires_in_seconds: 600,
    });
    expect(t.api.seen("POST", keys)[0]!.body).toEqual({ name: "Kitchen (dev_1)" });
    expect(t.api.seen("POST", offer)[0]!.body).toEqual({
      action: "started",
      device_id: "dev_1",
    });
  });

  it("are all or nothing: a key that cannot be made, or names no voice server, revokes what was made", async () => {
    const t = setup();
    t.api.on("POST", tokens, token);
    t.api.on("DELETE", tokens, { revoked: true });
    t.api.on("POST", keys, () => json(409, { error: "limit" }));
    expect(
      await t.call("connector.provisionDevice", { name: "Kitchen" })
    ).toMatchObject({
      error: { code: "limit", status: 409 },
    });
    expect(t.api.seen("DELETE", tokens)[0]!.body).toEqual({ token: "salix_conn_test" });

    t.api.on("POST", keys, () =>
      json(201, { ...key, readiness_url: "https://voice.test/elsewhere" })
    );
    t.api.on("DELETE", `${keys}/gak_1`, { deleted: true });
    expect(
      await t.call("connector.provisionDevice", { name: "Kitchen" })
    ).toMatchObject({
      error: { code: "bad_response" },
    });
    expect(t.api.seen("DELETE", `${keys}/gak_1`)).toHaveLength(1);
    expect(t.api.seen("DELETE", tokens)).toHaveLength(2);

    // A token that is no device's is revoked before any key is made.
    t.api.on("POST", tokens, {
      ...token,
      connect_url: "https://connect.test/v1/connect",
    });
    expect(
      await t.call("connector.provisionDevice", { name: "Kitchen" })
    ).toMatchObject({
      error: { code: "bad_response" },
    });
    expect(t.api.seen("POST", keys)).toHaveLength(2);
    expect(t.api.seen("DELETE", tokens)).toHaveLength(3);
  });

  it("are revoked: the token when kept, and the voice key by id or found by the device's name", async () => {
    const t = setup();
    t.api.on("DELETE", tokens, { revoked: true });
    t.api.on("GET", keys, [
      { ...key, key_id: "gak_other", name: "Android voice calls" },
      { ...key, key_id: "gak_found", name: "Hall (dev_2)" },
    ]);
    t.api.on("DELETE", `${keys}/gak_found`, () => json(404, { error: "not_found" }));
    expect(
      await t.call("connector.unprovisionDevice", {
        deviceId: "dev_2",
        connectorToken: "salix_conn_2",
      })
    ).toEqual({ value: null });
    expect(t.api.seen("DELETE", tokens)[0]!.body).toEqual({ token: "salix_conn_2" });
    expect(t.api.seen("DELETE", `${keys}/gak_found`)).toHaveLength(1);
    expect(t.api.seen("DELETE", `${keys}/gak_other`)).toHaveLength(0);

    // The token's revocation failing does not stop the key's; the failure is answered after.
    t.api.on("DELETE", tokens, () => json(503, { error: "busy" }));
    t.api.on("DELETE", `${keys}/gak_1`, { deleted: true });
    expect(
      await t.call("connector.unprovisionDevice", {
        deviceId: "dev_1",
        connectorToken: "salix_conn_1",
        voiceKeyId: "gak_1",
      })
    ).toMatchObject({ error: { code: "busy" } });
    expect(t.api.seen("DELETE", `${keys}/gak_1`)).toHaveLength(1);
  });
});
