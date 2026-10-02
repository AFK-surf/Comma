import { describe, expect, it, vi } from "vitest";
import {
  BftApiError,
  BftNotFoundError,
  createBftApi,
  csrfRejectedCode,
  csrfToken,
} from "../src/api";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

function apiReturning(response: Response, token: string | null = "tok-1") {
  const fetch = vi.fn<typeof globalThis.fetch>(async () => response);
  return {
    api: createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => token }),
    fetch,
  };
}

const membersPage = {
  viewer: { user_id: "u1", role: "owner", can_manage: true, can_grant_owner: true },
  members: [
    {
      user_id: "u2",
      name: null,
      email: null,
      mobile: "+10000000001",
      role: "auditor",
      joined_at: "2026-09-01T00:00:00Z",
      sso: true,
      sso_provider: "feishu",
    },
  ],
};

const runner = {
  id: "r1",
  stable_id: "lab",
  name: "Lab",
  status: "online",
  effective_status: "rebooting",
  host_identity: null,
  os_summary: null,
  version: null,
  component_versions: { "salix-connect": "2026.06.18" },
  update_available: true,
  capacity: 3,
  current_connector_count: 1,
  last_seen_at: null,
  last_seen_age_seconds: null,
  connectors: { total: 3, by_status: [{ status: "connected", count: 3 }] },
  credential: null,
};

describe("CSRF token", () => {
  it("reads the token Phoenix writes into the page", () => {
    const doc = {
      querySelector: (selector: string) =>
        selector === 'meta[name="csrf-token"]'
          ? { getAttribute: () => " abc123 " }
          : null,
    } as unknown as Document;
    expect(csrfToken(doc)).toBe("abc123");
    expect(csrfToken({ querySelector: () => null } as unknown as Document)).toBeNull();
    expect(csrfToken(undefined)).toBeNull();
  });
});

describe("member writes", () => {
  it("sends the CSRF header and JSON body, and parses the returned list", async () => {
    const { api, fetch } = apiReturning(json(200, { ok: true, data: membersPage }));
    const page = await api.changeMemberRole("acme co", "u 2", "admin");

    expect(fetch).toHaveBeenCalledWith(
      "/dashboard/api/v1/orgs/acme%20co/members/u%202",
      {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "x-csrf-token": "tok-1",
        },
        body: JSON.stringify({ role: "admin" }),
      }
    );
    // An unknown role is read as the least privileged one.
    expect(page.members[0]).toMatchObject({ role: "member", name: null, sso: true });
  });

  it("sends DELETE without a body", async () => {
    const { api, fetch } = apiReturning(json(200, { ok: true, data: membersPage }));
    await api.removeMember("acme", "u2");
    expect(fetch.mock.calls[0]?.[1]).toEqual({
      method: "DELETE",
      credentials: "same-origin",
      headers: { accept: "application/json", "x-csrf-token": "tok-1" },
    });
  });

  it("reports Plug's bare 403 as a refused CSRF token", async () => {
    const { api } = apiReturning(new Response("Forbidden", { status: 403 }), null);
    const error = await api
      .inviteMember("acme", { email: "a@b.c", role: "member" })
      .catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(BftApiError);
    expect(error).toMatchObject({ status: 403, code: csrfRejectedCode });
  });

  it("keeps the server's localized message for refused writes", async () => {
    const { api } = apiReturning(
      json(409, {
        ok: false,
        error: { code: "last_owner", message: "无法降级最后一位所有者。", details: {} },
      })
    );
    const error = await api
      .changeMemberRole("acme", "u1", "admin")
      .catch((caught: unknown) => caught);
    expect(error).toMatchObject({
      code: "last_owner",
      message: "无法降级最后一位所有者。",
    });

    const missing = apiReturning(
      json(404, {
        ok: false,
        error: { code: "member_not_found", message: "Member not found.", details: {} },
      })
    );
    const notFound = await missing.api
      .removeMember("acme", "u9")
      .catch((caught: unknown) => caught);
    expect(notFound).toBeInstanceOf(BftNotFoundError);
    expect(notFound).toMatchObject({
      code: "member_not_found",
      message: "Member not found.",
    });
  });
});

describe("runner reads and writes", () => {
  it("pages runners with an encoded cursor and falls back on unknown values", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: {
          viewer: { can_manage: false },
          runners: [runner],
          total_count: 26,
          cursor: "c/1",
          next_cursor: null,
          poll_interval_ms: 5000,
        },
      })
    );
    const page = await api.runners("acme", "c/1");
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/runners?cursor=c%2F1"
    );
    expect(page.runners[0]).toMatchObject({
      effective_status: "unknown",
      credential: null,
    });
    expect(page.poll_interval_ms).toBe(5000);
  });

  it("rotates a key with the CSRF header and returns the one-time command", async () => {
    const { api, fetch } = apiReturning(
      json(201, {
        ok: true,
        data: {
          command: "curl ... | sh",
          expires_at: "2026-10-01T00:15:00Z",
          runner_stable_id: "lab",
        },
      })
    );
    await expect(api.rotateRunnerKey("acme", "k1")).resolves.toMatchObject({
      command: "curl ... | sh",
    });
    const [url, init] = fetch.mock.calls[0] ?? [];
    expect(url).toBe("/dashboard/api/v1/orgs/acme/runners/keys/k1/rotate");
    expect(init).toMatchObject({
      method: "POST",
      headers: { "x-csrf-token": "tok-1" },
    });
  });

  it("surfaces an unavailable Server release by its code", async () => {
    const { api } = apiReturning(
      json(503, {
        ok: false,
        error: {
          code: "server_release_unavailable",
          message: "Server release is unavailable.",
          details: {},
        },
      })
    );
    await expect(api.createInstallCommand("acme")).rejects.toMatchObject({
      status: 503,
      code: "server_release_unavailable",
    });
  });
});
