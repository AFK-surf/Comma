import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  encodeSessionPresenceExpectation,
  sessionPresenceExpectationHeader,
} from "@comma/session-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  appRendererUrl,
  proxyCommaApiRequest,
  registerAppProtocol,
  registerPrivilegedSchemes,
  resolveRendererPath,
  type CommaApiCredentialAuthority,
} from "../protocol";
import type { MainProductCredentialLease } from "../modules/session";

const electronMocks = vi.hoisted(() => ({
  fetch: vi.fn(),
  handle: vi.fn(),
  registerSchemesAsPrivileged: vi.fn(),
}));

vi.mock("electron-log/main", () => ({ default: { warn: vi.fn() } }));

vi.mock("electron", () => ({
  net: {
    fetch: electronMocks.fetch,
  },
  session: {
    fromPartition: () => ({ fetch: electronMocks.fetch }),
  },
  protocol: {
    handle: electronMocks.handle,
    registerSchemesAsPrivileged: electronMocks.registerSchemesAsPrivileged,
  },
}));

describe("Electron app protocol", () => {
  beforeEach(() => {
    electronMocks.fetch.mockReset();
    electronMocks.handle.mockReset();
    electronMocks.registerSchemesAsPrivileged.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("registers assets as the internal renderer origin", () => {
    registerPrivilegedSchemes();

    expect(appRendererUrl()).toBe("assets://./");
    expect(electronMocks.registerSchemesAsPrivileged).toHaveBeenCalledWith(
      expect.arrayContaining([
        {
          scheme: "assets",
          privileges: expect.objectContaining({
            corsEnabled: true,
            secure: true,
            standard: true,
            supportFetchAPI: true,
          }),
        },
      ])
    );
  });

  it("falls back to index.html for missing and escaped renderer paths", () => {
    const rendererRoot = mkdtempSync(join(tmpdir(), "comma-renderer-"));

    try {
      writeFileSync(join(rendererRoot, "index.html"), "");
      writeFileSync(join(rendererRoot, "app.js"), "");

      expect(resolveRendererPath(rendererRoot, new URL("assets://./app.js"))).toBe(
        join(rendererRoot, "app.js")
      );
      expect(resolveRendererPath(rendererRoot, new URL("assets://./missing.js"))).toBe(
        join(rendererRoot, "index.html")
      );
      expect(
        resolveRendererPath(rendererRoot, new URL("assets://./%2e%2e/secret.txt"))
      ).toBe(join(rendererRoot, "index.html"));
    } finally {
      rmSync(rendererRoot, { force: true, recursive: true });
    }
  });

  it("returns dev renderer headers while bounding loaders until their bodies settle", async () => {
    const finishes: Array<() => void> = [];
    let active = 0;
    let peakActive = 0;
    electronMocks.fetch.mockImplementation(async () => {
      active += 1;
      peakActive = Math.max(peakActive, active);
      const finish = deferred<void>();
      finishes.push(() => finish.resolve());
      let settled = false;
      const settle = () => {
        if (settled) return;
        settled = true;
        active -= 1;
      };
      return new Response(
        new ReadableStream<Uint8Array>(
          {
            cancel() {
              settle();
            },
            async pull(controller) {
              await finish.promise;
              if (settled) return;
              settle();
              controller.enqueue(new TextEncoder().encode("export default true"));
              controller.close();
            },
          },
          { highWaterMark: 0 }
        ),
        { headers: { "content-type": "text/javascript" } }
      );
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const documentRequest = handler(new Request("assets://./"));
    const assetRequests = Array.from({ length: 39 }, (_, index) =>
      handler(new Request(`assets://./module-${index}.ts`))
    );
    // These responses return with their headers while every body is still open.
    const documentResponse = await documentRequest;
    const firstAssetBatch = await Promise.all(assetRequests.slice(0, 31));
    expect(electronMocks.fetch).toHaveBeenCalledTimes(32);
    expect(peakActive).toBe(32);

    const firstTexts = firstAssetBatch.slice(0, 8).map((response) => response.text());
    // The root document is the first fetch; finish eight assets successfully.
    finishes.slice(1, 9).forEach((finish) => finish());
    await expect(Promise.all(firstTexts)).resolves.toEqual(
      Array.from({ length: 8 }, () => "export default true")
    );

    const assetResponses = await Promise.all(assetRequests);
    expect(electronMocks.fetch).toHaveBeenCalledTimes(40);
    expect(peakActive).toBe(32);
    await Promise.all(
      [documentResponse, ...assetResponses.slice(8)].map((response) =>
        response.body?.cancel("test cleanup")
      )
    );
    expect(active).toBe(0);
  });

  it("reserves document admission while all ordinary dev asset permits are occupied", async () => {
    const fetchedUrls: string[] = [];
    let active = 0;
    let peakActive = 0;
    electronMocks.fetch.mockImplementation(async (url) => {
      fetchedUrls.push(url);
      active += 1;
      peakActive = Math.max(peakActive, active);
      let settled = false;
      return new Response(
        new ReadableStream<Uint8Array>(
          {
            cancel() {
              if (settled) return;
              settled = true;
              active -= 1;
            },
          },
          { highWaterMark: 0 }
        )
      );
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const assetRequests = Array.from({ length: 32 }, (_, index) =>
      handler(new Request(`assets://./stalled-${index}.ts`))
    );
    const activeAssetResponses = await Promise.all(assetRequests.slice(0, 31));
    expect(electronMocks.fetch).toHaveBeenCalledTimes(31);

    // The replacement document is not queued behind the old dev assets.
    const documentRequest = handler(new Request("assets://./"));
    const documentResponse = await documentRequest;
    expect(electronMocks.fetch).toHaveBeenCalledTimes(32);
    expect(fetchedUrls.at(-1)).toBe("https://vite.comma.test/");
    expect(peakActive).toBe(32);

    await documentResponse.body?.cancel("document consumed");
    await Promise.all(
      activeAssetResponses.map((response) => response.body?.cancel("navigation"))
    );
    const staleQueuedResponse = await assetRequests[31]!;
    expect(electronMocks.fetch).toHaveBeenCalledTimes(33);
    await staleQueuedResponse.body?.cancel("stale request cleanup");
    expect(active).toBe(0);
  });

  it("cancels a live dev renderer body and admits one queued asset without awaiting upstream teardown", async () => {
    const upstreamCancelled = deferred<void>();
    const upstreamCancelSettled = deferred<void>();
    const upstreamCancel = vi.fn((reason?: unknown) => {
      if (reason !== "navigation superseded") return undefined;
      upstreamCancelled.resolve();
      return upstreamCancelSettled.promise;
    });
    const upstreamPulled = deferred<void>();
    const upstreamPull = vi.fn(() => {
      upstreamPulled.resolve();
      return new Promise<void>(() => undefined);
    });
    const fetchSignals: AbortSignal[] = [];
    electronMocks.fetch.mockImplementation(async (_url, init) => {
      fetchSignals.push(init.signal as AbortSignal);
      return new Response(
        new ReadableStream<Uint8Array>(
          {
            cancel: upstreamCancel,
            pull: upstreamPull,
          },
          { highWaterMark: 0 }
        ),
        { headers: { "content-type": "text/javascript" } }
      );
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const requests = Array.from({ length: 33 }, (_, index) =>
      handler(new Request(`assets://./reload-${index}.ts`))
    );
    const firstBatch = await Promise.all(requests.slice(0, 31));
    expect(electronMocks.fetch).toHaveBeenCalledTimes(31);
    const reader = firstBatch[0]!.body!.getReader();
    const pendingRead = reader.read();
    await upstreamPulled.promise;
    expect(upstreamPull).toHaveBeenCalledTimes(1);
    expect(fetchSignals[0]?.aborted).toBe(false);

    const cancellation = reader.cancel("navigation superseded");
    expect(fetchSignals[0]?.aborted).toBe(true);
    expect(fetchSignals[0]?.reason).toBe("navigation superseded");
    await upstreamCancelled.promise;
    // Upstream teardown is still pending when the first queued asset is admitted.
    const admitted = await requests[31]!;
    expect(electronMocks.fetch).toHaveBeenCalledTimes(32);
    await expect(pendingRead).resolves.toEqual({ done: true, value: undefined });

    upstreamCancelSettled.resolve();
    await cancellation;
    await Promise.all([
      ...firstBatch.slice(1).map((response) => response.body?.cancel("test cleanup")),
      admitted.body?.cancel("test cleanup"),
    ]);
    const finalResponse = await requests[32]!;
    await finalResponse.body?.cancel("test cleanup");
  });

  it("links request cancellation to the proxied fetch and removes the link on completion", async () => {
    const fetchSignals: AbortSignal[] = [];
    electronMocks.fetch.mockImplementation(async (_url, init) => {
      fetchSignals.push(init.signal as AbortSignal);
      return new Response("export default true", {
        headers: { "content-type": "text/javascript" },
      });
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const requestController = new AbortController();
    const cancelledRequest = new Request("assets://./request-abort.ts", {
      signal: requestController.signal,
    });
    const removeCancelledListener = vi.spyOn(
      cancelledRequest.signal,
      "removeEventListener"
    );
    const cancelledResponse = await handler(cancelledRequest);

    requestController.abort("renderer request cancelled");
    expect(fetchSignals[0]?.aborted).toBe(true);
    expect(fetchSignals[0]?.reason).toBe("renderer request cancelled");
    expect(removeCancelledListener).toHaveBeenCalledWith("abort", expect.any(Function));
    await cancelledResponse.body?.cancel("test cleanup");

    const completedController = new AbortController();
    const completedRequest = new Request("assets://./request-complete.ts", {
      signal: completedController.signal,
    });
    const removeCompletedListener = vi.spyOn(
      completedRequest.signal,
      "removeEventListener"
    );
    const completedResponse = await handler(completedRequest);
    await expect(completedResponse.text()).resolves.toBe("export default true");
    expect(removeCompletedListener).toHaveBeenCalledWith("abort", expect.any(Function));

    completedController.abort("too late");
    expect(fetchSignals[1]?.aborted).toBe(false);
  });

  it("releases a dev renderer permit when the upstream body errors", async () => {
    let fetchIndex = 0;
    electronMocks.fetch.mockImplementation(async () => {
      const index = fetchIndex;
      fetchIndex += 1;
      return new Response(
        new ReadableStream<Uint8Array>(
          index === 0
            ? {
                pull(controller) {
                  controller.error(new Error("Vite body failed"));
                },
              }
            : {},
          { highWaterMark: 0 }
        )
      );
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const requests = Array.from({ length: 32 }, (_, index) =>
      handler(new Request(`assets://./body-error-${index}.ts`))
    );
    const firstBatch = await Promise.all(requests.slice(0, 31));

    await expect(firstBatch[0]!.text()).rejects.toThrow("Vite body failed");
    const admitted = await requests[31]!;
    expect(electronMocks.fetch).toHaveBeenCalledTimes(32);
    await Promise.all([
      ...firstBatch.slice(1).map((response) => response.body?.cancel("test cleanup")),
      admitted.body?.cancel("test cleanup"),
    ]);
  });

  it("releases dev renderer permits for bodyless responses and fetch rejection", async () => {
    let fetchIndex = 0;
    electronMocks.fetch.mockImplementation(async () => {
      const index = fetchIndex;
      fetchIndex += 1;
      if (index === 0) return new Response(null, { status: 204 });
      if (index === 1) throw new Error("Vite unavailable");
      return new Response(new ReadableStream<Uint8Array>({}, { highWaterMark: 0 }));
    });
    registerAppProtocol("https://vite.comma.test/");

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const bodyless = handler(new Request("assets://./bodyless.ts"));
    const rejected = handler(new Request("assets://./fetch-error.ts")).catch(
      (error: unknown) => error
    );
    const live = Array.from({ length: 31 }, (_, index) =>
      handler(new Request(`assets://./live-${index}.ts`))
    );

    await expect(bodyless).resolves.toMatchObject({ status: 204 });
    await expect(rejected).resolves.toEqual(new Error("Vite unavailable"));
    const liveResponses = await Promise.all(live);
    expect(electronMocks.fetch).toHaveBeenCalledTimes(33);
    await Promise.all(
      liveResponses.map((response) => response.body?.cancel("test cleanup"))
    );
  });

  it.each([
    "/v1/comma/auth/email/verify",
    "/v1/comma/%61uth/email/verify",
    "/v1%2Fcomma%2Fauth/email/verify",
    // The pre-namespace path, which the server still serves.
    "/v1/auth/email/verify",
    "/v1/%61uth/email/verify",
    "/v1%2Fauth/email/verify",
  ])(
    "blocks renderer auth requests before they reach the upstream: %s",
    async (path) => {
      registerAppProtocol();

      const handler = electronMocks.handle.mock.calls.find(
        ([scheme]) => scheme === "assets"
      )?.[1] as (request: Request) => Promise<Response>;
      const response = await handler(
        new Request(`assets://.${path}`, {
          body: JSON.stringify({ challenge_id: "challenge_1", code: "123456" }),
          method: "POST",
        })
      );

      expect(response.status).toBe(404);
      expect(response.headers.get("cache-control")).toBe("no-store");
      await expect(response.json()).resolves.toEqual({ error: "not_found" });
      expect(electronMocks.fetch).not.toHaveBeenCalled();
    }
  );

  it("makes a missing or stale renderer lease fail locally with zero network", async () => {
    const { authority } = fakeCredentialAuthority();
    registerAppProtocol(undefined, {
      getCredentialAuthority: () => authority,
    });

    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;
    const missing = await handler(
      new Request("assets://./v1/comma/workspaces", { method: "GET" })
    );
    const stale = await handler(
      commaApiRequest({
        generation: 8,
      })
    );

    expect(missing.status).toBe(409);
    expect(stale.status).toBe(409);
    await expect(stale.json()).resolves.toMatchObject({
      error: { code: "session_product_lease_unavailable" },
    });
    expect(electronMocks.fetch).not.toHaveBeenCalled();
  });

  it("ends the upstream request when its caller lets it go, and does not read it again", async () => {
    const { authority } = fakeCredentialAuthority();
    const upstreamSignal = deferred<AbortSignal>();
    electronMocks.fetch.mockImplementation(
      (_url: string, init: { signal: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          upstreamSignal.resolve(init.signal);
          init.signal.addEventListener("abort", () => reject(init.signal.reason));
        })
    );
    const caller = new AbortController();
    const request = new Request(commaApiRequest(), { signal: caller.signal });
    const answered = proxyCommaApiRequest(
      request,
      new URL("assets://./v1/comma/groups/grp_1/conversations/events"),
      authority,
      electronMocks.fetch
    );
    const upstream = await upstreamSignal.promise;
    caller.abort();
    expect(upstream.aborted).toBe(true);
    await answered;
    expect(electronMocks.fetch).toHaveBeenCalledOnce();
  });

  it("ends the upstream request when its answer's body is let go, whatever the caller's signal does", async () => {
    const { authority } = fakeCredentialAuthority();
    let upstream: AbortSignal | undefined;
    electronMocks.fetch.mockImplementation(
      (_url: string, init: { signal: AbortSignal }) => {
        upstream = init.signal;
        // An event stream: open until the server or the client ends it.
        return Promise.resolve(
          new Response(new ReadableStream<Uint8Array>(), {
            headers: { "content-type": "text/event-stream" },
            status: 200,
          })
        );
      }
    );
    // As Electron's protocol handler gives it: a request whose signal never aborts.
    const response = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/groups/grp_1/conversations/events"),
      authority,
      electronMocks.fetch
    );

    expect(upstream?.aborted).toBe(false);
    await response.body?.cancel();
    expect(upstream?.aborted).toBe(true);
  });

  it("acquires the exact lease, strips renderer authority, and injects only Main's bearer", async () => {
    const { authority } = fakeCredentialAuthority();
    electronMocks.fetch.mockResolvedValue(
      new Response("ok", {
        headers: {
          "cache-control": "private",
          "content-type": "text/plain",
        },
        status: 200,
      })
    );

    const response = await proxyCommaApiRequest(
      commaApiRequest(
        {},
        {
          authorization: "Bearer renderer_legacy",
          cookie: "ambient=secret",
          "idempotency-key": "req_1",
          "proxy-authorization": "Basic renderer_proxy",
          "x-comma-client-surface": "web",
          "x-comma-session-lifecycle-version": "999",
        }
      ),
      new URL("assets://./v1/comma/workspaces?limit=5"),
      authority,
      electronMocks.fetch
    );

    expect(response.status).toBe(200);
    expect(electronMocks.fetch).toHaveBeenCalledWith(
      "https://api.comma.example/v1/comma/workspaces?limit=5",
      expect.objectContaining({
        bypassCustomProtocolHandlers: true,
        credentials: "omit",
        method: "GET",
        redirect: "manual",
        signal: expect.any(AbortSignal),
      })
    );
    const init = electronMocks.fetch.mock.calls[0]?.[1] as { headers: Headers };
    expect(init.headers.get("authorization")).toBe("Bearer main_secret");
    expect(init.headers.get("cookie")).toBeNull();
    // A write's dedupe key reaches the server; without it an install request is rejected.
    expect(init.headers.get("idempotency-key")).toBe("req_1");
    expect(init.headers.get("proxy-authorization")).toBeNull();
    expect(init.headers.get("x-comma-client-surface")).toBeNull();
    expect(init.headers.get(sessionPresenceExpectationHeader)).toBeNull();
  });

  it("keeps Agent VMM install descriptors on the Main-only transport", async () => {
    const { authority } = fakeCredentialAuthority();
    registerAppProtocol(undefined, {
      fetch: electronMocks.fetch,
      getCredentialAuthority: () => authority,
    });
    const handler = electronMocks.handle.mock.calls.find(
      ([scheme]) => scheme === "assets"
    )?.[1] as (request: Request) => Promise<Response>;

    // Also the pre-namespace path, which the server still serves.
    for (const path of [
      "/v1/comma/workspaces/wsp_1/compute-nodes/agent-vmm/install-operations",
      "/v1/workspaces/wsp_1/compute-nodes/agent-vmm/install-operations",
    ]) {
      const response = await handler(
        new Request(`assets://.${path}`, { method: "POST" })
      );
      expect(response.status).toBe(404);
    }
    expect(electronMocks.fetch).not.toHaveBeenCalled();
  });

  it("rebuilds responses through an allowlist and never exposes authority headers", async () => {
    const { authority } = fakeCredentialAuthority();
    electronMocks.fetch.mockResolvedValue(
      new Response(JSON.stringify({ data: [] }), {
        headers: {
          authorization: "Bearer reflected",
          "cache-control": "private",
          "content-type": "application/json",
          location: "https://evil.example",
          "proxy-authenticate": "Basic realm=secret",
          "set-cookie": "comma_session=secret",
          "www-authenticate": "Bearer realm=secret",
          "x-comma-session-id": "session-secret",
        },
        status: 200,
      })
    );

    const response = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );

    expect(response.headers.get("content-type")).toBe("application/json");
    expect(response.headers.get("cache-control")).toBe("private");
    expect(response.headers.get("authorization")).toBeNull();
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("proxy-authenticate")).toBeNull();
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("www-authenticate")).toBeNull();
    expect(response.headers.get("x-comma-session-id")).toBeNull();
  });

  it("sends a read that got no response once more before reporting the upstream unavailable", async () => {
    vi.useFakeTimers();
    const { authority } = fakeCredentialAuthority();
    const url = new URL("assets://./v1/comma/workspaces");
    electronMocks.fetch
      .mockRejectedValueOnce(new Error("net::ERR_CONNECTION_CLOSED"))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));

    const recovered = proxyCommaApiRequest(
      commaApiRequest(),
      url,
      authority,
      electronMocks.fetch
    );
    await vi.advanceTimersByTimeAsync(300);

    await expect((await recovered).text()).resolves.toBe("ok");
    expect(electronMocks.fetch).toHaveBeenCalledTimes(2);

    electronMocks.fetch.mockReset();
    electronMocks.fetch.mockRejectedValue(
      new Error("net::ERR_TUNNEL_CONNECTION_FAILED")
    );
    const failed = proxyCommaApiRequest(
      commaApiRequest(),
      url,
      authority,
      electronMocks.fetch
    );
    await vi.advanceTimersByTimeAsync(300);

    expect((await failed).status).toBe(502);
    await expect((await failed).json()).resolves.toEqual({
      error: "upstream_unavailable",
    });
    expect(electronMocks.fetch).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  it("never replays a write that got no response", async () => {
    const { authority } = fakeCredentialAuthority();
    electronMocks.fetch.mockRejectedValue(new Error("net::ERR_CONNECTION_RESET"));

    const response = await proxyCommaApiRequest(
      new Request(commaApiRequest(), { body: "{}", method: "POST" }),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );

    expect(response.status).toBe(502);
    expect(electronMocks.fetch).toHaveBeenCalledOnce();
  });

  it("stops waiting to resend a read once the session lease ends", async () => {
    vi.useFakeTimers();
    let current = true;
    const { authority, controller } = fakeCredentialAuthority({
      isCurrent: () => current,
    });
    electronMocks.fetch.mockRejectedValue(new Error("net::ERR_NETWORK_CHANGED"));

    const pending = proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );
    await vi.advanceTimersByTimeAsync(0);
    current = false;
    controller.abort();

    expect((await pending).status).toBe(409);
    expect(electronMocks.fetch).toHaveBeenCalledOnce();
    vi.useRealTimers();
  });

  it("rejects redirects without contacting their target", async () => {
    const { authority } = fakeCredentialAuthority();
    electronMocks.fetch.mockResolvedValue(
      new Response(null, {
        headers: { location: "https://api-b.example/v1/comma/workspaces" },
        status: 307,
      })
    );

    const response = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({
      error: "upstream_redirect_blocked",
    });
    expect(response.headers.get("location")).toBeNull();
    expect(electronMocks.fetch).toHaveBeenCalledTimes(1);
    // The withheld answer does not keep its request open.
    expect(signalOfUpstreamCall(0).aborted).toBe(true);
  });

  it("settles the exact lease before delivery and reports only a current 401", async () => {
    const current = { value: true };
    const { authority, lease, reportUnauthorized } = fakeCredentialAuthority({
      isCurrent: () => current.value,
    });
    electronMocks.fetch.mockImplementation(async () => {
      current.value = false;
      return new Response("late", { status: 200 });
    });

    const staleResponse = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );
    expect(staleResponse.status).toBe(409);
    expect(reportUnauthorized).not.toHaveBeenCalled();
    expect(signalOfUpstreamCall(0).aborted).toBe(true);

    current.value = true;
    electronMocks.fetch.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "reflected" }), {
        headers: { "www-authenticate": "Bearer" },
        status: 401,
      })
    );
    const unauthorized = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );

    expect(reportUnauthorized).toHaveBeenCalledWith(lease);
    expect(unauthorized.status).toBe(401);
    await expect(unauthorized.json()).resolves.toEqual({ error: "unauthorized" });
    expect(unauthorized.headers.get("www-authenticate")).toBeNull();
    expect(signalOfUpstreamCall(1).aborted).toBe(true);
  });

  for (const path of [
    "/v1/comma/me/bootstrap",
    "/v1/comma/groups/grp_1/assistant-chat",
  ]) {
    it.each([401, 403, 404])(
      `reports only a 401 from POST ${path} to the session owner (%i)`,
      async (status) => {
        const { authority, lease, reportUnauthorized } = fakeCredentialAuthority();
        electronMocks.fetch.mockResolvedValue(
          new Response(JSON.stringify({ error: "refused" }), { status })
        );
        const request = new Request(`assets://.${path}`, {
          method: "POST",
          headers: commaApiRequest().headers,
        });
        const response = await proxyCommaApiRequest(
          request,
          new URL(request.url),
          authority,
          electronMocks.fetch
        );
        expect(response.status).toBe(status);
        expect(electronMocks.fetch).toHaveBeenCalledOnce();
        expect(electronMocks.fetch.mock.calls[0]?.[0]).toBe(`${lease.audience}${path}`);
        const sent = electronMocks.fetch.mock.calls[0]?.[1] as RequestInit;
        expect(sent.method).toBe("POST");
        expect(new Headers(sent.headers).get("authorization")).toBe(
          `Bearer ${lease.token}`
        );
        if (status === 401) {
          expect(reportUnauthorized).toHaveBeenCalledExactlyOnceWith(lease);
        } else {
          expect(reportUnauthorized).not.toHaveBeenCalled();
        }
        await response.text();
      }
    );
  }

  it("withholds delayed response bytes when the exact lease changes after headers arrive", async () => {
    const current = { account: "A" };
    const { authority, controller } = fakeCredentialAuthority({
      isCurrent: () => current.account === "A",
    });
    const bodyRelease = deferred<void>();
    const bodyPull = deferred<void>();
    const cancelUpstream = vi.fn();
    let delivered = false;
    const upstreamBody = new ReadableStream<Uint8Array>({
      async pull(bodyController) {
        if (delivered) return;
        delivered = true;
        bodyPull.resolve();
        await bodyRelease.promise;
        bodyController.enqueue(new TextEncoder().encode("account-a-secret"));
      },
      cancel: cancelUpstream,
    });
    electronMocks.fetch.mockResolvedValue(
      new Response(upstreamBody, {
        headers: { "content-type": "text/plain" },
        status: 200,
      })
    );

    const response = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/plain");

    const bodyRead = response.body?.getReader().read();
    expect(bodyRead).toBeDefined();
    await bodyPull.promise;

    current.account = "B";
    controller.abort();
    bodyRelease.resolve();

    await expect(bodyRead).rejects.toThrow(
      "The Electron Main Session lease changed before response-body delivery."
    );
    expect(cancelUpstream).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(cancelUpstream.mock.calls)).not.toContain("account-a-secret");
  });

  it("does not prefetch renderer bytes before a consumer read can settle the lease", async () => {
    const current = { account: "A" };
    const { authority, controller } = fakeCredentialAuthority({
      isCurrent: () => current.account === "A",
    });
    const pullUpstream = vi.fn(
      (bodyController: ReadableStreamDefaultController<Uint8Array>) => {
        bodyController.enqueue(new TextEncoder().encode("account-a-prefetched"));
      }
    );
    const cancelUpstream = vi.fn();
    electronMocks.fetch.mockResolvedValue(
      new Response(
        new ReadableStream<Uint8Array>(
          {
            cancel: cancelUpstream,
            pull: pullUpstream,
          },
          { highWaterMark: 0 }
        ),
        { status: 200 }
      )
    );

    const response = await proxyCommaApiRequest(
      commaApiRequest(),
      new URL("assets://./v1/comma/workspaces"),
      authority,
      electronMocks.fetch
    );
    await Promise.resolve();
    expect(pullUpstream).not.toHaveBeenCalled();

    current.account = "B";
    controller.abort();

    await expect(response.text()).rejects.toThrow(
      "The Electron Main Session lease changed before response-body delivery."
    );
    expect(pullUpstream).not.toHaveBeenCalled();
    expect(cancelUpstream).toHaveBeenCalledTimes(1);
  });
});

const canonicalLease: Omit<MainProductCredentialLease, "signal" | "token"> = {
  audience: "https://api.comma.example",
  authorityInstanceId: "authority-1",
  generation: 7,
  sessionId: "session-1",
};

function commaApiRequest(
  lease: Partial<typeof canonicalLease> = {},
  headers: HeadersInit = {}
) {
  const session = { ...canonicalLease, ...lease };
  return new Request("assets://./v1/comma/workspaces", {
    headers: {
      ...Object.fromEntries(new Headers(headers)),
      [sessionPresenceExpectationHeader]: encodeSessionPresenceExpectation({
        authorityInstanceId: session.authorityInstanceId,
        expectedAudience: session.audience,
        expectedSessionId: session.sessionId,
        generation: session.generation,
      }),
    },
    method: "GET",
  });
}

function fakeCredentialAuthority({
  isCurrent = () => true,
}: {
  isCurrent?: (() => boolean) | undefined;
} = {}) {
  const controller = new AbortController();
  const lease: MainProductCredentialLease = Object.freeze({
    ...canonicalLease,
    signal: controller.signal,
    token: "main_secret",
  });
  const reportUnauthorized = vi.fn();
  const authority: CommaApiCredentialAuthority = {
    acquireProductCredential(expected) {
      return expected.authorityInstanceId === canonicalLease.authorityInstanceId &&
        expected.expectedAudience === canonicalLease.audience &&
        expected.expectedSessionId === canonicalLease.sessionId &&
        expected.generation === canonicalLease.generation
        ? lease
        : null;
    },
    admissionFailure() {
      return {
        code: "session_product_lease_unavailable",
        recovery: {
          authorityInstanceId: canonicalLease.authorityInstanceId,
          generation: canonicalLease.generation,
          revision: 9,
        },
      };
    },
    isCurrentProductCredential(candidate) {
      return candidate === lease && isCurrent();
    },
    reportUnauthorized,
  };

  return { authority, controller, lease, reportUnauthorized };
}

/** The signal Main gave its `call`th upstream request. */
function signalOfUpstreamCall(call: number): AbortSignal {
  const init = electronMocks.fetch.mock.calls[call]?.[1] as
    | { signal: AbortSignal }
    | undefined;
  if (!init) throw new Error(`no upstream request ${call}`);
  return init.signal;
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((promiseResolve) => {
    resolve = promiseResolve;
  });
  return { promise, resolve };
}
