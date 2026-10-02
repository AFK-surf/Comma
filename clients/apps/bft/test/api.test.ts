import { describe, expect, it, vi } from "vitest";
import {
  BftApiError,
  BftNotFoundError,
  BftUnauthenticatedError,
  createBftApi,
} from "../src/api";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

function apiReturning(response: Response) {
  const fetch = vi.fn<typeof globalThis.fetch>(async () => response);
  const assignLocation = vi.fn<(href: string) => void>();
  return { api: createBftApi({ fetch, assignLocation }), fetch, assignLocation };
}

const overview = {
  project_count: 1,
  used_project_count: 1,
  conversation_count: 5,
  token_totals: { input: 1, output: 2, cache_read: 3, cache_write: 4, total: 10 },
  member_count: 2,
  runners: { total: 1, online: 0 },
  projects: [
    {
      id: "p1",
      name: "Support Desk",
      conversation_count: 5,
      token_total: 10,
      status: "ready",
      refreshed_at: null,
    },
  ],
  attention: [],
};

const projectOverview = {
  project: {
    id: "p 1",
    name: "Support Desk",
    slug: null,
    status: "active",
    created_at: "2026-09-01T00:00:00Z",
    created_by: null,
    role: "admin",
  },
  usage: {
    conversation_count: 100,
    token_total: 42,
    refreshed_at: null,
    status: "ready",
  },
  recent_conversations: [
    {
      id: "c1",
      title: null,
      status: null,
      updated_at: null,
      href: "/orgs/acme/projects/p%201/tasks/c1",
    },
  ],
  connected_providers: ["slack"],
  agents: {
    status: "ok",
    items: [
      {
        id: "a1",
        name: null,
        role: "router",
        lifecycle: "active",
        runtime: "internal",
      },
    ],
    truncated: false,
  },
};

describe("BFT API client", () => {
  it("sends same-origin JSON requests and unwraps the data envelope", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: { user: { id: "u1", name: null, email: "a@b.c" }, orgs: [] },
      })
    );
    await expect(api.session()).resolves.toEqual({
      user: { id: "u1", name: null, email: "a@b.c" },
      orgs: [],
    });
    expect(fetch).toHaveBeenCalledWith("/dashboard/api/v1/session", {
      credentials: "same-origin",
      headers: { accept: "application/json" },
    });
  });

  it("tolerates and drops extra fields", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        meta: { version: 2 },
        data: {
          ...overview,
          generated_at: "2026-09-30T00:00:00Z",
          projects: [{ ...overview.projects[0], color: "blue" }],
        },
      })
    );
    const parsed = await api.overview("acme co");
    expect(parsed.projects[0]).not.toHaveProperty("color");
    expect(parsed).not.toHaveProperty("generated_at");
    expect(fetch.mock.calls[0]?.[0]).toBe("/dashboard/api/v1/orgs/acme%20co/overview");
  });

  it("rejects bodies that break the contract", async () => {
    const { api } = apiReturning(
      json(200, { ok: true, data: { ...overview, member_count: "2" } })
    );
    await expect(api.overview("acme")).rejects.toMatchObject({
      code: "invalid_response",
    });
  });

  it("sends the browser to /login on 401", async () => {
    const { api, assignLocation } = apiReturning(
      json(401, {
        ok: false,
        error: { code: "unauthenticated", message: "Sign in", details: {} },
      })
    );
    await expect(api.orgContext("acme")).rejects.toBeInstanceOf(
      BftUnauthenticatedError
    );
    expect(assignLocation).toHaveBeenCalledWith("/login");
  });

  it("reports 404 as not found", async () => {
    const { api, assignLocation } = apiReturning(
      json(404, {
        ok: false,
        error: { code: "org_not_found", message: "Not found", details: {} },
      })
    );
    const error = await api.orgContext("nope").catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(BftNotFoundError);
    expect(error).toMatchObject({ status: 404, code: "org_not_found" });
    expect(assignLocation).not.toHaveBeenCalled();
  });

  it("surfaces other failures with the envelope message", async () => {
    const { api } = apiReturning(
      json(500, {
        ok: false,
        error: { code: "boom", message: "Exploded", details: {} },
      })
    );
    const error = await api.session().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(BftApiError);
    expect(error).toMatchObject({ status: 500, code: "boom", message: "Exploded" });
  });

  it("reads a project overview and falls back on unknown enum values", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: {
          ...projectOverview,
          project: { ...projectOverview.project, role: "owner" },
          usage: { ...projectOverview.usage, status: "exploded" },
          agents: {
            status: "degraded",
            truncated: true,
            items: [{ ...projectOverview.agents.items[0], runtime: "quantum" }],
          },
        },
      })
    );
    const parsed = await api.projectOverview("acme", "p 1");
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p%201/overview"
    );
    // An unknown role must not unlock admin-only actions.
    expect(parsed.project.role).toBe("user");
    expect(parsed.usage.status).toBe("missing");
    expect(parsed.agents.status).toBe("unavailable");
    expect(parsed.agents.items[0]?.runtime).toBe("internal");
  });

  it("reports a missing project with its error code", async () => {
    const { api } = apiReturning(
      json(404, {
        ok: false,
        error: {
          code: "project_not_found",
          message: "Agent Swarm not found.",
          details: {},
        },
      })
    );
    await expect(api.projectOverview("acme", "gone")).rejects.toMatchObject({
      status: 404,
      code: "project_not_found",
    });
  });

  it("reads org health and falls back on unknown enum values", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: {
          health: { status: "on_fire", reasons: ["Feishu bot disconnected"] },
          signals: [
            {
              key: "delivery",
              label: "Message delivery",
              detail: "All good",
              observed_at: null,
              status: "ok",
            },
            {
              key: "satellites",
              label: "Satellites",
              detail: "New signal kind",
              observed_at: "2026-09-30T00:00:00Z",
              status: "exploded",
            },
          ],
          runners: { total: 2, online: 1 },
          events: [
            {
              id: "e1",
              occurred_at: "2026-09-30T00:00:00Z",
              severity: "notice",
              title: "Runner offline",
              summary: "office-2",
              href: null,
            },
          ],
          audit_export_href: "/orgs/acme/operations/audit/export",
        },
      })
    );
    const parsed = await api.health("acme co");
    expect(fetch.mock.calls[0]?.[0]).toBe("/dashboard/api/v1/orgs/acme%20co/health");
    expect(parsed.health.status).toBe("unknown");
    expect(parsed.signals.map((signal) => signal.status)).toEqual(["ok", "unknown"]);
    expect(parsed.signals[1]?.key).toBe("satellites");
    expect(parsed.events[0]?.severity).toBe("notice");
  });

  it("keeps every known health status", async () => {
    for (const status of [
      "healthy",
      "degraded",
      "action_required",
      "critical",
      "unknown",
    ]) {
      const { api } = apiReturning(
        json(200, {
          ok: true,
          data: {
            health: { status, reasons: [] },
            signals: [],
            runners: { total: 0, online: 0 },
            events: [],
            audit_export_href: "/x",
          },
        })
      );
      await expect(api.health("acme")).resolves.toMatchObject({
        health: { status },
      });
    }
  });

  it("pages the audit log with an encoded cursor", async () => {
    const page = {
      entries: [
        {
          id: "a1",
          created_at: "2026-09-30T00:00:00Z",
          actor: "Maya Chen",
          action: "member.invited",
          resource: "li@acme.test",
          result: "success",
        },
      ],
      next_cursor: null,
    };
    const first = apiReturning(json(200, { ok: true, data: page }));
    await expect(first.api.audit("acme")).resolves.toEqual(page);
    expect(first.fetch.mock.calls[0]?.[0]).toBe("/dashboard/api/v1/orgs/acme/audit");

    const next = apiReturning(json(200, { ok: true, data: page }));
    await next.api.audit("acme", "c/2+3");
    expect(next.fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/audit?cursor=c%2F2%2B3"
    );
  });

  it("reports a member's health request as org not found", async () => {
    const { api } = apiReturning(
      json(404, {
        ok: false,
        error: { code: "org_not_found", message: "Not found", details: {} },
      })
    );
    await expect(api.health("acme")).rejects.toMatchObject({
      status: 404,
      code: "org_not_found",
    });
  });
});
