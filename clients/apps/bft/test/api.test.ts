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
});
