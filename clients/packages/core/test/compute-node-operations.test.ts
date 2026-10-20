import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const base = "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/install-operations/op1";
const target = { workspaceId: "wsp", operationId: "op1" };
const operation = (status: string) => ({
  operation: {
    id: "op1",
    authorization_status: "handed_off",
    status,
    work_activity: "idle",
  },
});

/** The session `signedIn()` gives the core, as Main names it. */
const lease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "authority-1",
  generation: 1,
  sessionId: "session-user-1",
};

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  // Main's own channel: it may make the calls that answer credentials.
  const client = new CoreClient(
    inProcessOpener(core, host, undefined, { host: true }),
    {
      schedule: () => undefined,
    }
  );
  const window = new CoreClient(inProcessOpener(core, host, "window-1"), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  return { client, window, core, time: host.time!, api: host.api };
}

describe("a compute node's install operation", () => {
  it("initializes the workload once the node reads ready, reading once a second", async () => {
    const t = setup();
    let reads = 0;
    t.api.on("GET", base, () =>
      json(200, operation(++reads < 3 ? "processing" : "ready"))
    );
    t.api.on("POST", `${base}/initialize-workload`, operation("ready"));
    const done = t.client.call("computeNode.initializeWorkload", target);
    await t.time.pass(100);
    expect(t.api.seen("GET", base)).toHaveLength(1);
    await t.time.pass(1_000, 500);
    expect(t.api.seen("GET", base)).toHaveLength(2);
    expect(t.api.seen("POST", `${base}/initialize-workload`)).toHaveLength(0);
    await t.time.pass(1_000, 500);
    await expect(done).resolves.toMatchObject({ status: "ready" });
    expect(t.api.seen("GET", base)).toHaveLength(3);
    expect(t.api.seen("POST", `${base}/initialize-workload`)).toHaveLength(1);
  });

  it("gives up after the wait, or at once when the node needs action, without initializing", async () => {
    const t = setup();
    t.api.on("GET", base, operation("processing"));
    const waited = t.client.call("computeNode.initializeWorkload", {
      ...target,
      waitMs: 3_000,
    });
    const outcome = expect(waited).rejects.toMatchObject({
      code: "initialization_incomplete",
    });
    await t.time.pass(5_000, 500);
    await outcome;
    expect(t.api.seen("GET", base)).toHaveLength(4);

    t.api.on("GET", base, operation("action_required"));
    const refused = t.client.call("computeNode.initializeWorkload", target);
    const refusal = expect(refused).rejects.toMatchObject({
      code: "initialization_incomplete",
    });
    await t.time.pass(100);
    await refusal;
    expect(t.api.seen("POST", `${base}/initialize-workload`)).toHaveLength(0);
  });
});

describe("Main's compute node requests", () => {
  const installs =
    "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/install-operations";
  const descriptor = {
    exchange_url:
      "https://api.comma.test/v1/compute/agent-vmm/install-operations/exchange",
    expires_at: "2026-08-25T00:00:00Z",
    one_time_secret: "ticket-secret",
    operation_id: "op1",
    version: 1,
  };

  it("authorizes an install for Main's session, idempotent by its request, and answers the descriptor", async () => {
    const t = setup();
    t.api.on("POST", installs, {
      descriptor,
      operation: { id: "op1", registration_id: "reg1" },
    });
    const answer = t.client.call("computeNode.authorize", {
      workspaceId: "wsp",
      requestId: "request-1",
      lease,
    });
    await t.time.pass(100);
    await expect(answer).resolves.toEqual({
      descriptor: JSON.stringify(descriptor),
      operationId: "op1",
      registrationId: "reg1",
    });
    const [sent] = t.api.seen("POST", installs);
    expect(sent!.headers).toContainEqual(["idempotency-key", "request-1"]);
    expect(sent!.body).toEqual({});
  });

  it("refuses a lease that is not the core's session, and a window's call, without a request", async () => {
    const t = setup();
    const other = t.client.call("computeNode.inspect", {
      ...target,
      lease: { ...lease, sessionId: "session-user-2" },
    });
    const refusedOther = expect(other).rejects.toMatchObject({
      code: "session_changed",
    });
    const fromWindow = t.window.call("computeNode.authorize", {
      workspaceId: "wsp",
      requestId: "request-1",
      lease,
    });
    const refusedWindow = expect(fromWindow).rejects.toMatchObject({
      code: "forbidden",
    });
    await t.time.pass(100);
    await refusedOther;
    await refusedWindow;
    expect(t.api.requests).toHaveLength(0);
  });

  it("gives up a request after 10 s on the Clock", async () => {
    const t = setup();
    t.api.on("GET", base, operation("ready"));
    t.api.hold("GET", base);
    const read = t.client.call("computeNode.inspect", { ...target, lease });
    const timedOut = expect(read).rejects.toMatchObject({ code: "timeout" });
    await t.time.pass(9_999);
    await t.time.pass(1);
    await timedOut;
  });
});

describe("Main's Connector credential requests", () => {
  const tokens = "/v1/comma/workspaces/wsp/connector-token";

  it("mints, revokes and names a refused stable device as the server did", async () => {
    const t = setup();
    t.api.on("POST", tokens, { token: "connector-token", server: "wss://salix.test" });
    t.api.on("DELETE", tokens, { revoked: true });
    const minted = t.client.call("connector.createToken", {
      workspaceId: "wsp",
      expiresInSeconds: 600,
      stableDeviceId: "device-1",
      lease,
    });
    const revoked = t.client.call("connector.revokeToken", {
      workspaceId: "wsp",
      token: "old-token",
      timeoutMs: 5_000,
      lease,
    });
    await t.time.pass(100);
    await expect(minted).resolves.toMatchObject({ token: "connector-token" });
    await expect(revoked).resolves.toBeNull();
    expect(t.api.seen("POST", tokens)[0]!.body).toEqual({
      expires_in_seconds: 600,
      stable_device_id: "device-1",
    });
    expect(t.api.seen("DELETE", tokens)[0]!.body).toEqual({ token: "old-token" });

    const named = t.client.call("connector.createToken", {
      workspaceId: "wsp",
      name: "Kitchen",
      registrationExpiresInSeconds: 600,
      lease,
    });
    await t.time.pass(100);
    await named;
    expect(t.api.seen("POST", tokens)[1]!.body).toEqual({
      name: "Kitchen",
      registration_expires_in_seconds: 600,
    });

    t.api.on("POST", tokens, () => json(403, { error: "stable_device_unavailable" }));
    const refused = t.client.call("connector.createToken", {
      workspaceId: "wsp",
      stableDeviceId: "device-1",
      lease,
    });
    const why = expect(refused).rejects.toMatchObject({
      code: "stable_device_unavailable",
      status: 403,
    });
    await t.time.pass(100);
    await why;
  });
});
