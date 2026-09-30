import { describe, expect, test } from "vitest";
import { createGateway, type GatewayEnv, type SandboxHandle } from "../src/app";
import { signRequest, stripControlPlaneHeaders } from "../src/auth";
import { parseSandboxId, sandboxIdFromPath } from "../src/ids";
import type { Sandbox } from "@cloudflare/sandbox";

describe("id parsing", () => {
  test("accepts path-safe sandbox ids", () => {
    expect(parseSandboxId("salix-vm-verify_1")).toBe("salix-vm-verify_1");
    expect(parseSandboxId("../bad")).toBeUndefined();
    expect(sandboxIdFromPath("/internal/v1/sandboxes/sb-1/connect")).toEqual({
      id: "sb-1",
      suffix: "/connect",
    });
  });
});

describe("auth", () => {
  test("strips Salix control-plane headers before proxying", () => {
    const headers = stripControlPlaneHeaders(
      new Headers({
        authorization: "Bearer secret",
        cookie: "a=b",
        "x-salix-signature": "sig",
        "x-salix-request-id": "rid",
        "x-custom": "ok",
      }),
    );
    expect(headers.get("authorization")).toBeNull();
    expect(headers.get("cookie")).toBeNull();
    expect(headers.get("x-salix-signature")).toBeNull();
    expect(headers.get("x-custom")).toBe("ok");
  });
});

describe("gateway routes", () => {
  test("healthz includes worker and connector version metadata", async () => {
    const app = createGateway<TestEnv>({ getSandbox: () => fakeSandbox() });
    const response = await app.fetch(
      new Request("https://gateway/healthz"),
      env(),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      ok: true,
      worker_version_id: "version-1",
      worker_version_tag: "tag-1",
      worker_version_timestamp: "2026-07-06T00:00:00Z",
      gateway_build_id: "build-1",
      connector_image_version: "connector-1",
    });
  });

  test("requires signed internal requests", async () => {
    const app = createGateway<TestEnv>({ getSandbox: () => fakeSandbox() });
    const response = await app.fetch(
      new Request("https://gateway/internal/v1/sandboxes/sb-1/status"),
      env(),
    );
    expect(response.status).toBe(401);
  });

  test("routes signed profiles to separate bindings and rejects path changes", async () => {
    const profiles: string[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: (_env, _id, _opts, profile) => {
        profiles.push(profile || "cf-standard-2");
        return fakeSandbox();
      },
    });
    const testEnv = env();
    const standard1 = "https://gateway/internal/v1/profiles/cf-standard-1/sandboxes/sb-1/status";
    const standard2 = "https://gateway/internal/v1/sandboxes/sb-1/status";

    expect((await app.fetch(await signedRequest(standard1), testEnv)).status).toBe(200);
    expect((await app.fetch(await signedRequest(standard2), testEnv)).status).toBe(200);
    expect(profiles).toEqual(["cf-standard-1", "cf-standard-2"]);

    const signed = await signedRequest(standard2);
    const changed = new Request(standard1, signed);
    expect((await app.fetch(changed, testEnv)).status).toBe(401);
    expect(profiles).toHaveLength(2);
  });

  test("ensure/status/destroy/checkpoint/restore use sandbox contract", async () => {
    const calls: string[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: (_env, id, opts) => fakeSandbox(calls, id, opts?.keepAlive),
    });
    const testEnv = env();

    const ensure = await app.fetch(
      await signedRequest("https://gateway/internal/v1/sandboxes", {
        method: "POST",
        body: { sandbox_id: "sb-1", keep_alive: true },
      }),
      testEnv,
    );
    expect(ensure.status).toBe(200);
    expect(await ensure.json()).toMatchObject({
      ok: true,
      sandbox_id: "sb-1",
      status: "ready",
      worker_version_id: "version-1",
      worker_version_tag: "tag-1",
      gateway_build_id: "build-1",
      connector_image_version: "connector-1",
    });

    const status = await app.fetch(
      await signedRequest("https://gateway/internal/v1/sandboxes/sb-1/status"),
      testEnv,
    );
    expect(status.status).toBe(200);

    const checkpoint = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/checkpoint",
        {
          method: "POST",
          body: { dir: "/workspace" },
        },
      ),
      testEnv,
    );
    expect(await checkpoint.json()).toMatchObject({
      ok: true,
      archive: { dir: "/workspace" },
    });

    const restore = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/restore",
        {
          method: "POST",
          body: { archive: { id: "archive-1" } },
        },
      ),
      testEnv,
    );
    expect(await restore.json()).toMatchObject({
      ok: true,
      restore: { restored: true },
    });

    const destroy = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/destroy",
        {
          method: "POST",
        },
      ),
      testEnv,
    );
    expect(destroy.status).toBe(200);
    expect(calls).toContain("get:sb-1:true");
    expect(calls).toContain("destroy:sb-1");
  });

  test("connect and proxy strip Salix auth material", async () => {
    const calls: Request[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: () => fakeSandbox(undefined, "sb-1", undefined, calls),
    });
    const testEnv = env();

    const proxy = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/proxy/readyz",
        {
          method: "GET",
        },
      ),
      testEnv,
    );
    expect(proxy.status).toBe(200);
    expect(proxy.headers.get("x-salix-container-response")).toBe("1");
    expect(calls[0].headers.get("x-salix-signature")).toBeNull();

    const connect = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/connect",
        {
          method: "GET",
          headers: { upgrade: "websocket" },
        },
      ),
      testEnv,
    );
    expect(connect.status).toBe(200);
    expect(await connect.json()).toEqual({ ok: true, upgraded: true });
    expect(new URL(calls[1].url).pathname).toBe("/connect");
    expect(calls[1].headers.get("upgrade")).toBe("websocket");
    expect(calls[1].headers.get("x-salix-signature")).toBeNull();
  });

  test("marks a completed Container error but not a Gateway error", async () => {
    const containerError = createGateway<TestEnv>({
      getSandbox: () => ({
        ...fakeSandbox(),
        containerFetch: async () => new Response("unavailable", { status: 503 }),
      }),
    });
    const request = await signedRequest(
      "https://gateway/internal/v1/sandboxes/sb-1/proxy/readyz",
    );
    const response = await containerError.fetch(request, env());
    expect(response.status).toBe(503);
    expect(response.headers.get("x-salix-container-response")).toBe("1");

    const gatewayError = createGateway<TestEnv>({
      getSandbox: () => {
        throw new Error("gateway failed");
      },
    });
    const failed = await gatewayError.fetch(request, env());
    expect(failed.status).toBe(500);
    expect(failed.headers.get("x-salix-container-response")).toBeNull();
  });

  test("proxy only allows diagnostic endpoints", async () => {
    const calls: Request[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: () => fakeSandbox(undefined, "sb-1", undefined, calls),
    });
    const testEnv = env();

    for (const path of [
      "/exec",
      "/connect",
      "/files/read",
      "/processes",
      "/diagnostics/../exec",
      "/diagnostics/%2e%2e/exec",
      "/diagnostics/%2E%2E/exec",
      "/diagnostics/%2fexec",
      "/diagnostics/%5c..%5cexec",
      "/diagnostics/%5C..%5Cexec",
    ]) {
      const response = await app.fetch(
        await signedRequest(
          `https://gateway/internal/v1/sandboxes/sb-1/proxy${path}`,
        ),
        testEnv,
      );
      expect(response.status).toBe(403);
    }
    expect(calls).toHaveLength(0);

    const diagnostics = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/proxy/diagnostics/runtime",
      ),
      testEnv,
    );
    expect(diagnostics.status).toBe(200);
    expect(new URL(calls[0].url).pathname).toBe("/diagnostics/runtime");
  });

  test("signatures cover forwarded query strings", async () => {
    const calls: Request[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: () => fakeSandbox(undefined, "sb-1", undefined, calls),
    });
    const testEnv = env();

    const signed = await signedRequest(
      "https://gateway/internal/v1/sandboxes/sb-1/proxy/readyz?probe=ok",
      {
        method: "GET",
      },
    );
    const ok = await app.fetch(signed, testEnv);
    expect(ok.status).toBe(200);
    expect(new URL(calls[0].url).search).toBe("?probe=ok");

    const tampered = new Request(
      "https://gateway/internal/v1/sandboxes/sb-1/proxy/readyz?probe=evil",
      signed,
    );
    const rejected = await app.fetch(tampered, testEnv);
    expect(rejected.status).toBe(401);
  });

  test("rejects oversized archive proxy bodies before forwarding", async () => {
    const calls: Request[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: () => fakeSandbox(undefined, "sb-1", undefined, calls),
    });
    const testEnv = { ...env(), SALIX_VM_GATEWAY_MAX_BODY_BYTES: "8" };

    const response = await app.fetch(
      await signedRequest(
        "https://gateway/internal/v1/sandboxes/sb-1/proxy/archive",
        {
          method: "PUT",
          body: "0123456789abcdef",
          rawBody: true,
        },
      ),
      testEnv,
    );

    expect(response.status).toBe(413);
    expect(calls).toHaveLength(0);
  });
});

type TestEnv = GatewayEnv;

function env(): TestEnv {
  return {
    SALIX_VM_GATEWAY_SECRET: "test-secret",
    VERSION_METADATA: {
      id: "version-1",
      tag: "tag-1",
      timestamp: "2026-07-06T00:00:00Z",
    },
    GATEWAY_BUILD_ID: "build-1",
    CONNECTOR_IMAGE_VERSION: "connector-1",
    Sandbox: {} as DurableObjectNamespace<Sandbox>,
    SandboxStandard1: {} as DurableObjectNamespace<Sandbox>,
  };
}

async function signedRequest(
  url: string,
  opts: {
    method?: string;
    body?: unknown;
    headers?: HeadersInit;
    rawBody?: boolean;
  } = {},
): Promise<Request> {
  const method = opts.method || "GET";
  const headers = new Headers(opts.headers);
  const body =
    opts.body === undefined
      ? undefined
      : opts.rawBody
        ? String(opts.body)
        : JSON.stringify(opts.body);
  if (body !== undefined && !opts.rawBody)
    headers.set("content-type", "application/json");
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonce = crypto.randomUUID();
  headers.set("x-salix-request-id", crypto.randomUUID());
  headers.set("x-salix-timestamp", timestamp);
  headers.set("x-salix-nonce", nonce);
  headers.set(
    "x-salix-signature",
    await signRequest(
      "test-secret",
      method,
      `${new URL(url).pathname}${new URL(url).search}`,
      timestamp,
      nonce,
      new TextEncoder().encode(body || "").buffer,
    ),
  );
  return new Request(url, { method, headers, body });
}

function fakeSandbox(
  calls: string[] = [],
  id = "sandbox",
  keepAlive?: boolean,
  requests: Request[] = [],
): SandboxHandle {
  calls.push(`get:${id}:${keepAlive}`);
  return {
    async containerFetch(request: Request) {
      requests.push(request);
      return Response.json({ ok: true, path: new URL(request.url).pathname });
    },
    async destroy() {
      calls.push(`destroy:${id}`);
    },
    async setKeepAlive(value: boolean) {
      calls.push(`keepalive:${id}:${value}`);
    },
    async createBackup(options: { dir: string }) {
      return { dir: options.dir };
    },
    async restoreBackup(_backup: unknown) {
      return { restored: true };
    },
    async wsConnect(request: Request) {
      requests.push(request);
      return Response.json({ ok: true, upgraded: true });
    },
  };
}
