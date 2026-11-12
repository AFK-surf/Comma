import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const base = "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/registrations/reg1";
const target = { workspaceId: "wsp", registrationId: "reg1" };
const operation = (status: string) => ({
  registration: {
    id: "reg1",
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

it("reads Registration status and the independent Shell phase", async () => {
  const t = setup();
  t.api.on("GET", base, {
    registration: {
      id: "reg1",
      status: "ready",
      work_activity: "idle",
      shell_phase: "failed",
    },
  });
  const read = t.client.call("computeNode.inspect", { ...target, lease });
  await t.time.pass(100);
  await expect(read).resolves.toEqual({
    status: "ready",
    workActivity: "idle",
    shellPhase: "failed",
  });
});

describe("Linux install command", () => {
  it("lets a member window request a Group-bound command without exposing a Main descriptor", async () => {
    const t = setup();
    const path = "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/install-commands";
    t.api.on("POST", path, {
      command:
        "curl -fsSL 'https://api.comma.test/v1/compute/agent-vmm/install.sh' | sudo sh -s -- linux-op.secret",
      expires_at: "2026-10-23T10:00:00Z",
      registration: { id: "linux-op" },
    });
    const answer = t.window.call("computeNode.installCommand", {
      workspaceId: "wsp",
      requestId: "linux-request",
    });
    await t.time.pass(100);
    await expect(answer).resolves.toEqual({
      command:
        "curl -fsSL 'https://api.comma.test/v1/compute/agent-vmm/install.sh' | sudo sh -s -- linux-op.secret",
      expiresAt: "2026-10-23T10:00:00Z",
    });
    expect(t.api.seen("POST", path)[0]!.headers).toContainEqual([
      "idempotency-key",
      "linux-request",
    ]);
    expect(t.api.seen("POST", path)[0]!.body).toEqual({});
  });
});

describe("Main's compute node requests", () => {
  const installs = "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/registrations";
  const descriptor = {
    claim_url: "https://api.comma.test/v1/compute/agent-vmm/registrations/claim",
    expires_at: "2026-08-25T00:00:00Z",
    ticket: "ticket-secret",
    registration_id: "reg1",
    request_id: "enable-request",
    version: 1,
  };

  it("authorizes an install for Main's session, idempotent by its request, and answers the descriptor", async () => {
    const t = setup();
    t.api.on("POST", installs, {
      descriptor,
      registration: { id: "reg1", registration_id: "reg1" },
    });
    const answer = t.client.call("computeNode.authorize", {
      workspaceId: "wsp",
      requestId: "request-1",
      lease,
    });
    await t.time.pass(100);
    const authorization = (await answer) as {
      descriptor: string;
      registrationId: string;
    };
    expect(authorization.registrationId).toBe("reg1");
    expect(JSON.parse(authorization.descriptor)).toEqual(descriptor);
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

it("cancels the original Registration request through the current Main lease", async () => {
  const t = setup();
  const path =
    "/v1/comma/workspaces/wsp/compute-nodes/agent-vmm/registrations/requests/original-client-request/cancel";
  t.api.on("POST", path, {
    registration: { id: "revoked-pending", status: "removed", host_bound: false },
  });
  const answer = t.client.call("computeNode.cancelRequest", {
    workspaceId: "wsp",
    requestId: "original-client-request",
    lease,
  });
  await t.time.pass(100);
  await expect(answer).resolves.toEqual({
    registrationId: "revoked-pending",
    hostBound: false,
  });
  expect(t.api.seen("POST", path)[0]!.body).toEqual({});
});
