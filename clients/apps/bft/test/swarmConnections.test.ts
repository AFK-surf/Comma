import { describe, expect, it, vi } from "vitest";
import { createBftApi } from "../src/api";
import { evidenceText, gateStatus, providerSection } from "../src/SwarmConnectionsPage";

const ok = (data: unknown) =>
  new Response(JSON.stringify({ ok: true, data }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

function apiAnswering(data: unknown) {
  const fetch = vi.fn<typeof globalThis.fetch>(async () => ok(data));
  return {
    api: createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => "tok-1" }),
    fetch,
  };
}

const page = {
  project: { id: "p 1", name: "Support", role: "admin" },
  org_admin: true,
  messaging: {
    status: "ok",
    feishu: {
      apps: [{ app_id: "cli_1", name: "Acme" }],
      connects: [],
      route: { status: "rerouted", connect_id: null, router: null },
    },
    slack: null,
  },
  signal: { status: "ok", number: null, bindings: [], bindings_truncated: false },
  accounts: { status: "booting", connections: [], providers: [] },
  composio: { status: "ok", configured: false, toolkits: [] },
};

describe("Agent Swarm Connections", () => {
  it("reads the page leniently: unknown states read as unknown or unavailable", async () => {
    const { api, fetch } = apiAnswering(page);
    const data = await api.swarmConnections("acme", "p 1");

    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p%201/connections"
    );
    expect(data.messaging.feishu?.route.status).toBe("unknown");
    expect(data.accounts.status).toBe("unavailable");
  });

  it("writes to escaped addresses; a Signal code alone changes nothing read", async () => {
    const { api, fetch } = apiAnswering({ notice: "Connect disabled." });
    const changed = vi.fn();
    api.onWrite(changed);

    await api.setImConnectEnabled("acme", "p1", "imc/1", false);
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p1/connections/im/imc%2F1/enablement"
    );
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "PUT",
      headers: { "x-csrf-token": "tok-1" },
      body: JSON.stringify({ enabled: false }),
    });
    expect(changed).toHaveBeenCalledTimes(1);

    const claim = apiAnswering({
      claim: { number: "+1555", command: "comma connect A" },
    });
    const claimed = vi.fn();
    claim.api.onWrite(claimed);
    await expect(claim.api.createSignalClaim("acme", "p1")).resolves.toEqual({
      number: "+1555",
      command: "comma connect A",
    });
    expect(claimed).not.toHaveBeenCalled();

    const manifest = apiAnswering({ manifest: null });
    await manifest.api.slackManifest("acme", "p1", "  ");
    await manifest.api.slackManifest("acme", "p1", "Acme Bot");
    expect(manifest.fetch.mock.calls.map((call) => call[0])).toEqual([
      "/dashboard/api/v1/orgs/acme/projects/p1/connections/slack/manifest",
      "/dashboard/api/v1/orgs/acme/projects/p1/connections/slack/manifest?app_name=Acme+Bot",
    ]);
  });

  it("reads a connect's member scope, the organization's when unsaid, and changes it", async () => {
    const read = apiAnswering({
      ...page,
      messaging: {
        ...page.messaging,
        feishu: {
          ...page.messaging.feishu,
          connects: [{ connect_id: "imc1_feishu", member_scope: "partner" }],
        },
      },
    });
    const data = await read.api.swarmConnections("acme", "p 1");
    expect(data.messaging.feishu?.connects[0]).toMatchObject({
      member_scope: "organization",
      member_grants: [],
    });

    const { api, fetch } = apiAnswering({ notice: "People here are external now." });
    const changed = vi.fn();
    api.onWrite(changed);
    await api.setMemberScope("acme", "p1", "lark", "imc/1", "external");
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p1/connections/lark/imc%2F1/member-scope"
    );
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "PUT",
      body: JSON.stringify({ scope: "external" }),
    });
    expect(changed).toHaveBeenCalledTimes(1);

    // A new app's scan sends the chosen scope with each ask; an update sends none.
    const scan = apiAnswering({ state: "pending", registration: "sealed-1" });
    await scan.api.pollFeishuRegistration("acme", "p1", "sealed-0", "external");
    await scan.api.pollLarkRegistration("acme", "p1", "sealed-0");
    expect(scan.fetch.mock.calls.map(([path, init]) => [path, init?.body])).toEqual([
      [
        "/dashboard/api/v1/orgs/acme/projects/p1/connections/feishu/registration/poll",
        JSON.stringify({ registration: "sealed-0", member_scope: "external" }),
      ],
      [
        "/dashboard/api/v1/orgs/acme/projects/p1/connections/lark/registration/poll",
        JSON.stringify({ registration: "sealed-0" }),
      ],
    ]);
  });

  it("finds a person of a connect, gives them access with an expiry, and removes it", async () => {
    const found = apiAnswering({
      people: [{ subject: "U07", name: "Sam Rivera", email: "sam@globex.test" }],
      complete: false,
    });
    await expect(
      found.api.connectPeople("acme", "p1", "slack", "imc1", "sam r")
    ).resolves.toEqual({
      people: [{ subject: "U07", name: "Sam Rivera", email: "sam@globex.test" }],
      complete: false,
    });
    expect(found.fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p1/connections/slack/imc1/people?query=sam+r"
    );

    const { api, fetch } = apiAnswering({ notice: "Access changed." });
    const changed = vi.fn();
    api.onWrite(changed);
    await api.grantMemberAccess("acme", "p1", "slack", "imc1", {
      subject: "U07",
      expires_in_days: 7,
    });
    await api.revokeMemberAccess("acme", "p1", "slack", "imc1", "U/07");
    expect(
      fetch.mock.calls.map(([path, init]) => [init?.method, path, init?.body])
    ).toEqual([
      [
        "POST",
        "/dashboard/api/v1/orgs/acme/projects/p1/connections/slack/imc1/member-grants",
        JSON.stringify({ subject: "U07", expires_in_days: 7 }),
      ],
      [
        "DELETE",
        "/dashboard/api/v1/orgs/acme/projects/p1/connections/slack/imc1/member-grants/U%2F07",
        undefined,
      ],
    ]);
    expect(changed).toHaveBeenCalledTimes(2);
  });

  it("calls a retrying calendar check pending, not a manual step", () => {
    expect(
      gateStatus({
        status: "needs_manual",
        reason_class: "calendar_enrollment_retrying",
      })
    ).toBe("pending");
    expect(
      gateStatus({
        status: "needs_manual",
        reason_class: "explicit_admin_action_required",
      })
    ).toBe("needs_manual");
    expect(gateStatus({ status: "surprising", reason_class: null })).toBe("skipped");
  });

  it("shows evidence as text and follows only its own provider deep links", () => {
    expect(evidenceText(["Comma Event", "Team"])).toBe("Comma Event, Team");
    expect(evidenceText({ app_id: "cli_1" })).toBe('{"app_id":"cli_1"}');
    expect(evidenceText(false)).toBe("false");
    expect(providerSection("?provider=slack")).toBe("slack");
    expect(providerSection("?provider=accounts")).toBeNull();
  });
});
