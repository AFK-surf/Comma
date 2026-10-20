import { describe, expect, test } from "vitest";
import { createGateway, type GatewayEnv, type SandboxHandle } from "../src/app";
import { signRequest } from "../src/auth";
import { parseSandboxId, sandboxIdFromPath } from "../src/ids";
import type { ManagedSandbox } from "../src/managed_sandbox";
import type { ControlPermit } from "../src/control";

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

describe("gateway routes", () => {
  test("owner permits are signed and legacy mutable requests cannot reach the DO", async () => {
    const calls: string[] = [];
    const app = createGateway<TestEnv>({ getSandbox: () => fakeSandbox(calls) });
    const testEnv = env();
    const target = "https://gateway/internal/v1/sandboxes/sb-1/ensure";
    const missing = await app.fetch(await signedRequest(target, { method: "POST", body: {}, control: false }), testEnv);
    expect(missing.status).toBe(409);
    expect(calls).toEqual([]);
    const signed = await signedRequest(target, { method: "POST", body: {} });
    const changed = new URL(signed.url);
    changed.searchParams.set("salix_control", JSON.stringify({ owner_id: "another-workload" }));
    expect((await app.fetch(new Request(changed, signed), testEnv)).status).toBe(401);
    expect(calls).toEqual([]);
  });

  test("nothing reaches the Container: connect and proxy paths are gone", async () => {
    const calls: string[] = [];
    const app = createGateway<TestEnv>({ getSandbox: () => fakeSandbox(calls, "sb-1") });
    const testEnv = env();
    const observed = await app.fetch(await signedRequest("https://gateway/internal/v1/sandboxes/sb-1/control", { control: false }), testEnv);
    expect(await observed.json()).toMatchObject({ running: false, control: null });
    for (const path of ["/connect", "/proxy/readyz", "/proxy/archive", "/receipt?operation=x"]) {
      const response = await app.fetch(await signedRequest(`https://gateway/internal/v1/sandboxes/sb-1${path}`, { headers: { upgrade: "websocket" } }), testEnv);
      expect(response.status).toBe(404);
    }
    expect(calls.filter((c) => !c.startsWith("get:"))).toEqual([]);
  });

  test("ensure gives the Container its station's server and credential, and refuses anything else", async () => {
    const stations: unknown[] = [];
    const handle = fakeSandbox();
    handle.salixEnsure = async (_permit, _keepAlive, station) => {
      stations.push(station);
      return { running: true, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null };
    };
    const app = createGateway<TestEnv>({ getSandbox: () => handle });
    const testEnv = env();
    for (const bad of [undefined, { server: "ws://salix.example", credential: "c" }, { server: "wss://salix.example", credential: "" }, { server: "wss://salix.example", credential: "a b" }]) {
      const refused = await app.fetch(await signedRequest("https://gateway/internal/v1/sandboxes", { method: "POST", body: { sandbox_id: "sb-1", station: bad } }), testEnv);
      expect(refused.status).toBe(400);
    }
    expect(stations).toEqual([]);
    const ok = await app.fetch(await signedRequest("https://gateway/internal/v1/sandboxes", { method: "POST", body: { sandbox_id: "sb-1", station: { server: "wss://salix.example", credential: "connect-credential" } } }), testEnv);
    expect(await ok.json()).toMatchObject({ status: "started", running: true });
    expect(stations).toEqual([{ SALIX_SERVER: "wss://salix.example", SALIX_WORKLOAD_CREDENTIAL: "connect-credential" }]);
  });

  test("ensure gives the Container the archive a wake names to restore before its station starts, as Salix encoded it", async () => {
    const stations: unknown[] = [];
    const handle = fakeSandbox();
    handle.salixEnsure = async (_permit, _keepAlive, station) => {
      stations.push(station);
      return { running: true, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null };
    };
    const app = createGateway<TestEnv>({ getSandbox: () => handle });
    const testEnv = env();
    const station = { server: "wss://salix.example", credential: "connect-credential" };
    // Anything but Salix's one bounded base64 string is refused: the Container is not started without its disk.
    for (const restore of ["", "not base64!", { operation: "archive-1" }, null, "A".repeat(8 * 1024 + 4)]) {
      const refused = await app.fetch(await signedRequest("https://gateway/internal/v1/sandboxes", { method: "POST", body: { sandbox_id: "sb-1", station: { ...station, restore } } }), testEnv);
      expect(refused.status).toBe(400);
      expect(await refused.json()).toMatchObject({ error: { code: "invalid_station" } });
    }
    expect(stations).toEqual([]);
    const ok = await app.fetch(await signedRequest("https://gateway/internal/v1/sandboxes", { method: "POST", body: { sandbox_id: "sb-1", station: { ...station, restore: "H4sIAAAAAAAAA6tWyi9ILUosyS9SslIqSc7PBQBs7xjLFAAAAA==" } } }), testEnv);
    expect(await ok.json()).toMatchObject({ status: "started", running: true });
    expect(stations).toEqual([{ SALIX_SERVER: "wss://salix.example", SALIX_WORKLOAD_CREDENTIAL: "connect-credential", SALIX_RESTORE_ARCHIVE: "H4sIAAAAAAAAA6tWyi9ILUosyS9SslIqSc7PBQBs7xjLFAAAAA==" }]);
  });

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
      getSandbox: (_env, _id, profile) => {
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

  test("managed commands use owner permits and reject SDK backup fallback", async () => {
    const calls: string[] = [];
    const app = createGateway<TestEnv>({
      getSandbox: (_env, id) => fakeSandbox(calls, id),
    });
    const testEnv = env();

    const ensure = await app.fetch(
      await signedRequest("https://gateway/internal/v1/sandboxes", {
        method: "POST",
        body: { sandbox_id: "sb-1", keep_alive: true, station: { server: "wss://salix.example", credential: "connect-credential" } },
      }),
      testEnv,
    );
    expect(ensure.status).toBe(200);
    expect(await ensure.json()).toMatchObject({
      ok: true,
      sandbox_id: "sb-1",
      status: "started",
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
    expect(checkpoint.status).toBe(409);
    expect(await checkpoint.json()).toMatchObject({ error: { code: "provider_archive_required" } });

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
    expect(restore.status).toBe(409);

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
    expect(calls).toContain("ensure:sb-1:true");
    expect(calls).toContain("destroy:sb-1");
  });

  test("only a signed explicit discard request authorizes disk disposal", async () => {
    const decisions: boolean[] = [];
    const handle = fakeSandbox();
    handle.salixDestroy = async (_permit, discard) => {
      decisions.push(discard === true);
      return { running: false, control: null, managed_commands_settled: true, last_stop: null, last_uncommanded_stop: null };
    };
    const app = createGateway<TestEnv>({ getSandbox: () => handle });
    const testEnv = env();
    const url = "https://gateway/internal/v1/sandboxes/sb-1/destroy";
    const signed = await signedRequest(url, { method: "POST", body: { discard: false } });
    expect((await app.fetch(new Request(signed, { body: JSON.stringify({ discard: true }) }), testEnv)).status).toBe(401);
    expect(decisions).toEqual([]);
    expect((await app.fetch(await signedRequest(url, { method: "POST" }), testEnv)).status).toBe(200);
    expect((await app.fetch(await signedRequest(url, { method: "POST", body: { discard: true } }), testEnv)).status).toBe(200);
    expect(decisions).toEqual([false, true]);
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
    Sandbox: {} as DurableObjectNamespace<ManagedSandbox>,
    SandboxStandard1: {} as DurableObjectNamespace<ManagedSandbox>,
  };
}

async function signedRequest(
  url: string,
  opts: {
    method?: string;
    body?: unknown;
    headers?: HeadersInit;
    rawBody?: boolean;
    control?: false | ControlPermit;
  } = {},
): Promise<Request> {
  const method = opts.method || "GET";
  const target = new URL(url);
  if (opts.control !== false) target.searchParams.set("salix_control", JSON.stringify(opts.control ?? {
    owner_id: "workload-1", operation_id: "wake-1", generation: 1, revision: 1, claim_id: crypto.randomUUID(),
  }));
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
      `${target.pathname}${target.search}`,
      timestamp,
      nonce,
      new TextEncoder().encode(body || "").buffer,
    ),
  );
  return new Request(target, { method, headers, body });
}

function fakeSandbox(
  calls: string[] = [],
  id = "sandbox",
  keepAlive?: boolean,
): SandboxHandle {
  calls.push(`get:${id}:${keepAlive}`);
  return {
    async salixDestroy() {
      calls.push(`destroy:${id}`);
      return { running: false, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null };
    },
    async salixKeepAlive(_permit: ControlPermit, value: boolean) {
      calls.push(`keepalive:${id}:${value}`);
    },
    async salixEnsure(_permit: ControlPermit, value: boolean) {
      calls.push(`ensure:${id}:${value}`);
      return { running: false, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null };
    },
    async salixObserve() { return { running: false, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null }; },
    async salixOpen() { return { running: false, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null }; },
    async salixSeal() { return { running: false, control: null, managed_commands_settled: false, last_stop: null, last_uncommanded_stop: null }; },
  };
}
