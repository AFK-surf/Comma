import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../wrangler.worker";

describe("Comma web static worker", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("does not expose a second same-origin Comma API ingress", async () => {
    const fetchMock = vi.fn();
    const assetsFetch = vi.fn(async (_request: Request) => {
      return new Response("static", { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await worker.fetch(
      new Request("https://app.comma.surf/v1/comma/auth/email/login?next=1", {
        body: JSON.stringify({ email: "person@example.com" }),
        headers: {
          authorization: "Bearer comma_sess_test",
          host: "app.comma.surf",
          origin: "https://app.comma.surf",
        },
        method: "POST",
      }),
      {
        ASSETS: {
          fetch: assetsFetch,
        },
      }
    );

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toEqual({
      error: "direct_api_origin_required",
    });
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(assetsFetch).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("continues to serve non-API application assets", async () => {
    const assetsFetch = vi.fn(async () => new Response("app", { status: 200 }));
    const request = new Request("https://app.comma.surf/settings");

    const response = await worker.fetch(request, {
      ASSETS: { fetch: assetsFetch },
    });

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("app");
    expect(assetsFetch).toHaveBeenCalledWith(request);
  });

  it("serves the share page on the public link path without leaking its token", async () => {
    // Asset HTML handling canonicalizes /share.html; the browser must not follow it.
    const assetsFetch = vi.fn(async (request: Request) =>
      new URL(request.url).pathname === "/share.html"
        ? new Response(null, { status: 307, headers: { location: "/share" } })
        : new Response("share page", {
            status: 200,
            headers: { "content-type": "text/html" },
          })
    );

    const response = await worker.fetch(
      new Request(`https://app.comma.surf/s/${"a".repeat(43)}`),
      { ASSETS: { fetch: assetsFetch } }
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("share page");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("x-robots-tag")).toBe("noindex");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(
      assetsFetch.mock.calls.map(([request]) => new URL(request.url).pathname)
    ).toEqual(["/share.html", "/share"]);
  });

  it("serves the app runtime as a sandboxed document without app content", async () => {
    const assetsFetch = vi.fn();

    const response = await worker.fetch(
      new Request("https://app.comma.surf/app-runtime/"),
      {
        ASSETS: { fetch: assetsFetch },
      }
    );

    expect(response.status).toBe(200);
    const policy = response.headers.get("content-security-policy") ?? "";
    expect(policy.split("; ")).toEqual(
      expect.arrayContaining([
        "sandbox allow-scripts allow-forms",
        "connect-src 'none'",
        expect.stringMatching(/^script-src 'sha256-[A-Za-z0-9+/]+=*' blob:$/),
      ])
    );
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).toMatch(/^<!doctype html>/);
    expect(assetsFetch).not.toHaveBeenCalled();
  });

  it("opens an app link in the main app without leaking its token", async () => {
    const assetsFetch = vi.fn(async (request: Request) =>
      new URL(request.url).pathname === "/"
        ? new Response("main app", { headers: { "content-type": "text/html" } })
        : new Response("other", { status: 404 })
    );

    const response = await worker.fetch(
      new Request(`https://app.comma.surf/a/${"b".repeat(32)}`),
      { ASSETS: { fetch: assetsFetch } }
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("main app");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("x-robots-tag")).toBe("noindex");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("keeps staging out of search indexes and leaves production indexable", async () => {
    const assetsFetch = vi.fn(async () => new Response("app", { status: 200 }));
    const env = { ASSETS: { fetch: assetsFetch } };

    const staging = await worker.fetch(
      new Request("https://app-staging.comma.surf/"),
      env
    );
    const production = await worker.fetch(new Request("https://app.comma.surf/"), env);

    expect(staging.status).toBe(200);
    expect(await staging.text()).toBe("app");
    expect(staging.headers.get("x-robots-tag")).toBe("noindex");
    expect(production.headers.get("x-robots-tag")).toBeNull();
  });
});
