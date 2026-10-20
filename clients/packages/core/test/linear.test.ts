import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { LinearValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "ws-1";
const path = `/v1/comma/workspaces/${WS}/integrations/linear`;
const topic: Topic = { topic: "linear", workspace: WS };

/** The workspace's link: its person in the organization, which this workspace installed Comma into. */
type Link = {
  id: string;
  updated_at: string;
  completion_state_policy: "unchanged" | "in_review" | "done";
  revoked: boolean;
};

const integration = (link: Link | null) => ({
  configured: true,
  installation: link
    ? {
        id: "linear_install_1",
        organization_id: "org-1",
        organization_name: "Acme",
        organization_url_key: "acme",
        installer: true,
        revoked: link.revoked,
        installed_at: "2026-10-07T00:00:00Z",
        updated_at: "2026-10-07T00:00:00Z",
      }
    : null,
  member: link
    ? {
        id: link.id,
        linear_user_id: "linear-user-1",
        linear_user_name: "Yue",
        linear_user_email: "yue@acme.test",
        completion_state_policy: link.completion_state_policy,
        linked_at: "2026-10-07T00:00:00Z",
        updated_at: link.updated_at,
      }
    : null,
  completion_state_policies: ["unchanged", "in_review", "done"],
  workspace_id: WS,
  workspace_name: "Main",
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: WS, group_id: "g-1", name: "Main" }],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(t: Topic) => {
    const key = topicKey(t);
    const stop = client.subscribe(
      t,
      (v) => values.set(key, v),
      () => undefined
    );
    return Object.assign(() => values.get(key) as T, { stop });
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

/**
 * A Linear that links after `installsAfter` reads following a connect, keeps settings it is sent, and fails the
 * reads numbered in `failing`.
 */
function linearServer(t: ReturnType<typeof setup>, initial: Link | null) {
  const server = {
    installation: initial,
    installsAfter: Infinity,
    failing: new Set<number>(),
  };
  t.api.on("GET", path, () => {
    const connected = t.api.seen("POST", `${path}/connect`).length > 0;
    const reads = t.api.seen("GET", path).length;
    if (server.failing.has(reads)) return json(503, { error: "unavailable" });
    if (connected && reads > server.installsAfter && !server.installation)
      server.installation = {
        id: "linear_member_1",
        updated_at: "2026-10-07T01:00:00Z",
        completion_state_policy: "unchanged",
        revoked: false,
      };
    return json(200, integration(server.installation));
  });
  t.api.on("POST", `${path}/connect`, {
    authorization_url:
      "https://linear.app/oauth/authorize?actor=app&state=dev.attempt-1",
    expires_at: "2026-10-07T00:10:00Z",
  });
  t.api.on("PATCH", path, (request: { body?: unknown }) => {
    const body = (request.body ?? {}) as Partial<Link>;
    if (!server.installation) return json(404, { error: "not_found" });
    server.installation = {
      ...server.installation,
      ...(body.completion_state_policy
        ? { completion_state_policy: body.completion_state_policy }
        : {}),
      updated_at: "2026-10-07T02:00:00Z",
    };
    return json(200, integration(server.installation).member);
  });
  t.api.on("DELETE", path, () => {
    const removed = Boolean(server.installation);
    server.installation = null;
    return json(200, { disconnected: removed });
  });
  return server;
}

describe("Linear", () => {
  it("reads the workspace's link while shown", async () => {
    const t = setup();
    linearServer(t, {
      id: "linear_member_0",
      updated_at: "2026-10-06T00:00:00Z",
      completion_state_policy: "in_review",
      revoked: false,
    });
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      error: false,
      busy: false,
      attempt: null,
      state: {
        configured: true,
        installation: { organization_name: "Acme", installer: true },
        member: { id: "linear_member_0", completion_state_policy: "in_review" },
      },
    });
  });

  it("follows a connect every 1.5 s until the link shows", async () => {
    const t = setup();
    const server = linearServer(t, null);
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);
    expect(shown().state?.member).toBeNull();
    server.installsAfter = 4;

    const started = t.client.call("linear.connect", {
      workspace: WS,
      environment: "dev",
    });
    await t.time.pass(100);
    expect(await started).toEqual({
      authorizationUrl:
        "https://linear.app/oauth/authorize?actor=app&state=dev.attempt-1",
    });
    expect(t.api.seen("POST", `${path}/connect`)[0]!.body).toEqual({
      environment: "dev",
    });
    expect(shown()).toMatchObject({ attempt: "dev.attempt-1", busy: true });

    // Reads at 0 s, 1.5 s and 3 s do not show it yet; the one at 4.5 s does.
    await t.time.pass(3_100);
    expect(shown()).toMatchObject({ attempt: "dev.attempt-1", busy: true });
    await t.time.pass(3_000);
    expect(shown()).toMatchObject({
      attempt: null,
      busy: false,
      error: false,
      state: { member: { id: "linear_member_1" } },
    });
    const reads = t.api.seen("GET", path).length;
    await t.time.pass(10_000);
    expect(t.api.seen("GET", path)).toHaveLength(reads);
  });

  it("keeps following through failed reads, and gives up after 3 in a row", async () => {
    const t = setup();
    const server = linearServer(t, null);
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);
    // Reads 2 and 3 (the first two follow reads) fail; read 4 lands the link.
    server.failing = new Set([2, 3]);
    server.installsAfter = 3;
    await t.client.call("linear.connect", { workspace: WS, environment: "dev" });
    await t.time.pass(5_000);
    expect(shown()).toMatchObject({
      attempt: null,
      busy: false,
      error: false,
      state: { member: { id: "linear_member_1" } },
    });

    const failing = linearServer(t, null);
    await t.client.call("linear.disconnect", { workspace: WS });
    await t.time.pass(100);
    const before = t.api.seen("GET", path).length;
    failing.failing = new Set([before + 1, before + 2, before + 3]);
    await t.client.call("linear.connect", { workspace: WS, environment: "dev" });
    await t.time.pass(5_000);
    expect(shown()).toMatchObject({
      attempt: "dev.attempt-1",
      busy: false,
      error: true,
    });
    await t.time.pass(10_000);
    expect(t.api.seen("GET", path)).toHaveLength(before + 3);
  });

  it("cancels a connect whose window closed, as a failure, and reads again on a plain cancel", async () => {
    const t = setup();
    linearServer(t, null);
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);
    await t.client.call("linear.connect", { workspace: WS, environment: "dev" });
    await t.time.pass(100);
    await t.client.call("linear.cancel", { workspace: WS, closed: true });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ attempt: null, busy: false, error: true });

    await t.client.call("linear.connect", { workspace: WS, environment: "dev" });
    await t.time.pass(100);
    const reads = t.api.seen("GET", path).length;
    await t.client.call("linear.cancel", { workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ attempt: null, busy: false, error: false });
    expect(t.api.seen("GET", path).length).toBe(reads + 1);
  });

  it("changes the completion policy, then disconnects", async () => {
    const t = setup();
    linearServer(t, {
      id: "linear_member_0",
      updated_at: "2026-10-06T00:00:00Z",
      completion_state_policy: "unchanged",
      revoked: false,
    });
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);

    await t.client.call("linear.updateSettings", {
      workspace: WS,
      completion_state_policy: "done",
    });
    await t.time.pass(100);
    expect(t.api.seen("PATCH", path)[0]!.body).toEqual({
      completion_state_policy: "done",
    });
    expect(shown().state?.member).toMatchObject({ completion_state_policy: "done" });

    await expect(
      t.client.call("linear.updateSettings", { workspace: WS })
    ).rejects.toThrow("nothing to change");

    await t.client.call("linear.disconnect", { workspace: WS });
    await t.time.pass(100);
    expect(t.api.seen("DELETE", path)).toHaveLength(1);
    expect(t.api.seen("DELETE", path)[0]!.path).toBe(path);
    expect(shown()).toMatchObject({
      busy: false,
      error: false,
      state: { member: null },
    });

    // The installer removes Comma from the organization itself.
    await t.client.call("linear.disconnect", { workspace: WS, scope: "organization" });
    await t.time.pass(100);
    expect(t.api.seen("DELETE", path)[1]!.path).toBe(`${path}?scope=organization`);
  });

  it("shows a failed read until the next refresh", async () => {
    const t = setup();
    t.api.on("GET", path, () => json(503, { error: "unavailable" }));
    const shown = t.watch<LinearValue>(topic);
    await t.time.pass(100);
    expect(shown()).toMatchObject({ error: true, state: null });

    linearServer(t, null);
    await t.client.call("linear.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ error: false, state: { configured: true } });
  });
});
