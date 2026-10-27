import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { createDispatch, type DispatchEnv } from "../src/app";
import { signRequest } from "../src/auth";
import { ReplayGuard } from "../src/replay_guard";

const NOW = Date.UTC(2026, 9, 24, 12, 0, 0);
const SECRET = "test-secret";
const app = createDispatch<DispatchEnv>();

beforeEach(() => {
  vi.useFakeTimers({ now: NOW });
});
afterEach(() => {
  vi.useRealTimers();
});

type Call = { script: string; options: unknown; request: Request; body: string };

function env(behavior: (request: Request) => Promise<Response> = async () => Response.json({ ok: true })) {
  const calls: Call[] = [];
  const dispatcher = {
    get(script: string, _args: unknown, options: unknown) {
      if (script === "app-missing-v1") throw new Error("Worker not found.");
      return {
        async fetch(request: Request) {
          calls.push({ script, options, request, body: await request.clone().text() });
          return behavior(request);
        },
      };
    },
  } as unknown as DispatchNamespace;
  const testEnv: DispatchEnv = {
    MINIAPP_DISPATCH_SECRET: SECRET,
    MINIAPP_DISPATCH_MAX_BODY_BYTES: "1024",
    ReplayGuard: replayGuards(),
    DISPATCHER: dispatcher,
  };
  return { env: testEnv, calls };
}

// The real ReplayGuard class on an in-memory storage, one instance per name.
function replayGuards(): DurableObjectNamespace {
  const guards = new Map<string, ReplayGuard>();
  return {
    idFromName: (name: string) => name,
    get(id: string) {
      let guard = guards.get(id);
      if (!guard) {
        const data = new Map<string, unknown>();
        const storage = {
          get: async (key: string) => data.get(key),
          put: async (key: string, value: unknown) => void data.set(key, value),
          setAlarm: async () => {},
          deleteAll: async () => data.clear(),
        };
        guard = new ReplayGuard({ storage } as unknown as DurableObjectState);
        guards.set(id, guard);
      }
      const target = guard;
      return { fetch: (url: string, init: RequestInit) => target.fetch(new Request(url, init)) };
    },
  } as unknown as DurableObjectNamespace;
}

async function signed(
  path: string,
  opts: { method?: string; body?: string; headers?: Record<string, string>; nonce?: string; timestamp?: number; secret?: string } = {},
): Promise<Request> {
  const method = opts.method ?? "POST";
  const url = new URL(`https://miniapp-dispatch.test${path}`);
  const timestamp = String(opts.timestamp ?? Math.floor(NOW / 1000));
  const nonce = opts.nonce ?? "nonce-1";
  const body = new TextEncoder().encode(opts.body ?? "");
  const signature = await signRequest(opts.secret ?? SECRET, method, `${url.pathname}${url.search}`, timestamp, nonce, body.buffer as ArrayBuffer);
  return new Request(url, {
    method,
    body: method === "GET" ? undefined : body,
    headers: {
      "x-salix-request-id": "req-1",
      "x-salix-timestamp": timestamp,
      "x-salix-nonce": nonce,
      "x-salix-signature": signature,
      "content-type": "application/json",
      "x-comma-app-method": "POST",
      "x-comma-app-version": "3",
      "x-comma-viewer": "viewer-abc",
      "x-comma-app-egress": "api.open-meteo.com, Example.org",
      ...opts.headers,
    },
  });
}

describe("dispatch Worker", () => {
  test("a signed request runs the Version script with the limits, the egress list and only the app headers", async () => {
    const { env: testEnv, calls } = env();
    const response = await app.fetch(
      await signed("/internal/v1/apps/app-x7k2q9-v3/api/items?page=2", {
        body: '{"name":"a"}',
        headers: { "x-comma-app-method": "PUT", "x-comma-extra": "secret", "x-salix-other": "x", cookie: "c=1" },
      }),
      testEnv,
    );
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call.script).toBe("app-x7k2q9-v3");
    expect(call.options).toEqual({
      limits: { cpuMs: 50, subRequests: 50 },
      outbound: { egress: ["api.open-meteo.com", "example.org"], app: "x7k2q9" },
    });
    expect(call.request.method).toBe("PUT");
    expect(new URL(call.request.url).pathname + new URL(call.request.url).search).toBe("/api/items?page=2");
    expect(call.body).toBe('{"name":"a"}');
    const headers = Object.fromEntries(call.request.headers.entries());
    expect(headers).toEqual({
      "content-type": "application/json",
      "x-comma-app-version": "3",
      "x-comma-viewer": "viewer-abc",
    });
  });

  test("unsigned, wrongly signed, stale and replayed requests reach no app and answer 404", async () => {
    const { env: testEnv, calls } = env();
    const path = "/internal/v1/apps/app-x7k2q9-v3/run";

    const unsigned = new Request(`https://miniapp-dispatch.test${path}`, { method: "POST", body: "{}" });
    expect((await app.fetch(unsigned, testEnv)).status).toBe(404);
    expect((await app.fetch(await signed(path, { secret: "other", nonce: "n-bad" }), testEnv)).status).toBe(404);
    expect((await app.fetch(await signed(path, { timestamp: Math.floor(NOW / 1000) - 301, nonce: "n-old" }), testEnv)).status).toBe(404);

    // The body is part of the signature.
    const original = await signed(path, { body: '{"a":1}', nonce: "n-body" });
    const tampered = new Request(original.url, { method: "POST", headers: original.headers, body: '{"a":2}' });
    expect((await app.fetch(tampered, testEnv)).status).toBe(404);
    expect(calls).toHaveLength(0);

    const first = await signed(path, { nonce: "n-once" });
    const replay = first.clone() as Request;
    expect((await app.fetch(first, testEnv)).status).toBe(200);
    expect((await app.fetch(replay, testEnv)).status).toBe(404);
    expect(calls).toHaveLength(1);
  });

  test("without a secret or a replay guard every request is refused", async () => {
    const { env: testEnv, calls } = env();
    const path = "/internal/v1/apps/app-x7k2q9-v3/run";
    expect((await app.fetch(await signed(path), { ...testEnv, MINIAPP_DISPATCH_SECRET: undefined })).status).toBe(404);
    expect((await app.fetch(await signed(path, { nonce: "n-2" }), { ...testEnv, ReplayGuard: undefined })).status).toBe(404);
    expect(calls).toHaveLength(0);
  });

  test("only Version scripts and the internal route are reachable", async () => {
    const { env: testEnv, calls } = env();
    expect((await app.fetch(await signed("/internal/v1/apps/app-x7k2q9-data/run", { nonce: "a" }), testEnv)).status).toBe(404);
    expect((await app.fetch(await signed("/internal/v1/apps/other-script/run", { nonce: "b" }), testEnv)).status).toBe(404);
    expect((await app.fetch(await signed("/api/run", { nonce: "c" }), testEnv)).status).toBe(404);
    expect((await app.fetch(await signed("/internal/v1/apps/app-missing-v1/run", { nonce: "d" }), testEnv)).status).toBe(404);
    expect(calls).toHaveLength(0);
    const health = await app.fetch(new Request("https://miniapp-dispatch.test/healthz"), testEnv);
    expect(health.status).toBe(200);
  });

  test("a body over the limit is refused before it reaches the app", async () => {
    const { env: testEnv, calls } = env();
    const response = await app.fetch(await signed("/internal/v1/apps/app-x7k2q9-v3/run", { body: "x".repeat(1025) }), testEnv);
    expect(response.status).toBe(413);
    expect(calls).toHaveLength(0);
  });

  test("an invalid egress list or app method is refused", async () => {
    const { env: testEnv, calls } = env();
    const path = "/internal/v1/apps/app-x7k2q9-v3/run";
    for (const [nonce, headers] of [
      ["e1", { "x-comma-app-egress": "10.0.0.1" }],
      ["e2", { "x-comma-app-egress": "*.example.com" }],
      ["e3", { "x-comma-app-method": "CONNECT" }],
    ] as const) {
      expect((await app.fetch(await signed(path, { nonce, headers }), testEnv)).status).toBe(400);
    }
    expect(calls).toHaveLength(0);
  });

  test("an error the app script throws becomes 502 app_error", async () => {
    const { env: testEnv } = env(async () => {
      throw new Error("boom in app");
    });
    const response = await app.fetch(await signed("/internal/v1/apps/app-x7k2q9-v3/run"), testEnv);
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "app_error", message: "boom in app" });
  });

  test("the app response passes through", async () => {
    const { env: testEnv } = env(async () => new Response("teapot", { status: 418, headers: { "content-type": "text/plain" } }));
    const response = await app.fetch(await signed("/internal/v1/apps/app-x7k2q9-v3/run"), testEnv);
    expect(response.status).toBe(418);
    expect(await response.text()).toBe("teapot");
  });
});
