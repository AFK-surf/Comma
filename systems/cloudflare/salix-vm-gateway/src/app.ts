import { authorize, stripControlPlaneHeaders, type AuthEnv } from "./auth";
import { sandboxIdFromPath, parseSandboxId } from "./ids";
import { errorJson, json, readJsonObject } from "./json";
import type { Sandbox } from "@cloudflare/sandbox";

export type SandboxHandle = {
  containerFetch(request: Request, port?: number): Promise<Response>;
  destroy(): Promise<void>;
  setKeepAlive?(keepAlive: boolean): Promise<void>;
  createBackup?(options: { dir: string }): Promise<unknown>;
  restoreBackup?(backup: unknown): Promise<unknown>;
  wsConnect(request: Request, port: number): Promise<Response>;
};

export type GatewayEnv = AuthEnv & {
  Sandbox: DurableObjectNamespace<Sandbox>;
  SandboxStandard1: DurableObjectNamespace<Sandbox>;
  VERSION_METADATA?: WorkerVersionMetadata;
  GATEWAY_BUILD_ID?: string;
  CONNECTOR_IMAGE_VERSION?: string;
};

type GatewayDeps<EnvType extends GatewayEnv> = {
  getSandbox(
    env: EnvType,
    id: string,
    opts?: { keepAlive?: boolean },
    profile?: "cf-standard-1" | "cf-standard-2",
  ): SandboxHandle;
};

const READY_PROBE_TIMEOUT_MS = 20_000;

export function createGateway<EnvType extends GatewayEnv>(
  deps: GatewayDeps<EnvType>,
) {
  return {
    async fetch(request: Request, env: EnvType): Promise<Response> {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz")
        return json({ ok: true, ...versionMetadata(env) });
      if (!url.pathname.startsWith("/internal/v1/sandboxes") &&
          !url.pathname.startsWith("/internal/v1/profiles/")) {
        return errorJson("not_found", 404);
      }

      const auth = await authorize(request, env);
      if (!auth.ok) return auth.response;

      try {
        return await route(request, env, deps, auth.requestId);
      } catch (error) {
        return errorJson(
          "gateway_error",
          500,
          error instanceof Error ? error.message : "gateway error",
          auth.requestId,
        );
      }
    },
  };
}

async function route<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  requestId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const standard1Prefix = "/internal/v1/profiles/cf-standard-1";
  const profile = url.pathname.startsWith(standard1Prefix + "/")
    ? "cf-standard-1" : "cf-standard-2";
  const pathname = profile === "cf-standard-1"
    ? "/internal/v1" + url.pathname.slice(standard1Prefix.length) : url.pathname;
  if (!pathname.startsWith("/internal/v1/sandboxes")) {
    return errorJson("not_found", 404, "unknown profile", requestId);
  }
  const selectedDeps: GatewayDeps<EnvType> = {
    getSandbox: (selectedEnv, id, opts) => deps.getSandbox(selectedEnv, id, opts, profile),
  };
  if (pathname === "/internal/v1/sandboxes" && request.method === "POST") {
    return ensureSandbox(request, env, selectedDeps, requestId);
  }

  const parsed = sandboxIdFromPath(pathname);
  if (!parsed)
    return errorJson(
      "invalid_sandbox_id",
      400,
      "invalid sandbox id",
      requestId,
    );

  switch (parsed.suffix) {
    case "/ensure":
      if (request.method !== "POST")
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      return ensureSandbox(request, env, selectedDeps, requestId, parsed.id);
    case "/status":
      if (request.method !== "GET" && request.method !== "POST") {
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      }
      return sandboxStatus(env, selectedDeps, parsed.id, requestId);
    case "/checkpoint":
      if (request.method !== "POST")
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      return checkpoint(request, env, selectedDeps, parsed.id, requestId);
    case "/restore":
      if (request.method !== "POST")
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      return restore(request, env, selectedDeps, parsed.id, requestId);
    case "/keepalive":
      if (request.method !== "POST")
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      return keepalive(request, env, selectedDeps, parsed.id, requestId);
    case "/destroy":
      if (request.method !== "POST" && request.method !== "DELETE") {
        return errorJson(
          "method_not_allowed",
          405,
          "method not allowed",
          requestId,
        );
      }
      return destroy(env, selectedDeps, parsed.id);
    case "/connect":
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return errorJson(
          "upgrade_required",
          426,
          "websocket upgrade required",
          requestId,
          { upgrade: "websocket" },
        );
      }
      return connect(request, env, selectedDeps, parsed.id);
    default:
      if (parsed.suffix.startsWith("/proxy/"))
        return proxy(request, env, selectedDeps, parsed.id, parsed.suffix);
      return errorJson("not_found", 404, "not found", requestId);
  }
}

async function ensureSandbox<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  requestId: string,
  pathId?: string,
): Promise<Response> {
  const body = await readJsonObject(request);
  const requestedId =
    pathId || parseSandboxId(body.sandbox_id as string | undefined);
  if (!requestedId)
    return errorJson(
      "invalid_sandbox_id",
      400,
      "invalid sandbox id",
      requestId,
    );

  const keepAlive = body.keep_alive === true;
  const sandbox = deps.getSandbox(env, requestedId, { keepAlive });
  if (typeof sandbox.setKeepAlive === "function") {
    await sandbox.setKeepAlive(keepAlive);
  }
  const ready = await probeContainer(
    sandbox,
    "/readyz",
    READY_PROBE_TIMEOUT_MS,
  );
  logGatewayEvent("sandbox_ensure", env, {
    sandbox_id: requestedId,
    request_id: requestId,
    ready_status: ready.status,
  });
  return json({
    ok: true,
    sandbox_id: requestedId,
    status: ready.ok ? "ready" : "starting",
    ready_status: ready.status,
    request_id: requestId,
    ...versionMetadata(env),
  });
}

async function sandboxStatus<EnvType extends GatewayEnv>(
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
  requestId: string,
): Promise<Response> {
  const sandbox = deps.getSandbox(env, id);
  const health = await probeContainer(
    sandbox,
    "/healthz",
    READY_PROBE_TIMEOUT_MS,
  );
  logGatewayEvent("sandbox_status", env, {
    sandbox_id: id,
    request_id: requestId,
    health_status: health.status,
  });
  return json({
    ok: true,
    sandbox_id: id,
    status: health.ok ? "ready" : "starting",
    health_status: health.status,
    request_id: requestId,
    ...versionMetadata(env),
  });
}

async function probeContainer(
  sandbox: SandboxHandle,
  path: "/healthz" | "/readyz",
  timeoutMs: number,
): Promise<{ ok: boolean; status: number | "timeout" }> {
  const response = await Promise.race([
    sandbox.containerFetch(new Request(`http://localhost:8080${path}`), 8080),
    new Promise<"timeout">((resolve) =>
      setTimeout(() => resolve("timeout"), timeoutMs),
    ),
  ]);
  if (response === "timeout") return { ok: false, status: "timeout" };
  return { ok: response.ok, status: response.status };
}

async function checkpoint<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
  requestId: string,
): Promise<Response> {
  const body = await readJsonObject(request);
  const dir = typeof body.dir === "string" ? body.dir : "/workspace";
  const backup = await deps.getSandbox(env, id).createBackup?.({ dir });
  if (!backup)
    return errorJson(
      "checkpoint_unsupported",
      501,
      "checkpoint is unsupported by sandbox binding",
      requestId,
    );
  logGatewayEvent("sandbox_checkpoint", env, {
    sandbox_id: id,
    request_id: requestId,
  });
  return json({
    ok: true,
    sandbox_id: id,
    archive: backup,
    request_id: requestId,
    ...versionMetadata(env),
  });
}

async function restore<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
  requestId: string,
): Promise<Response> {
  const body = await readJsonObject(request);
  if (!("archive" in body))
    return errorJson("missing_archive", 400, "missing archive", requestId);
  const restored = await deps.getSandbox(env, id).restoreBackup?.(body.archive);
  if (!restored)
    return errorJson(
      "restore_unsupported",
      501,
      "restore is unsupported by sandbox binding",
      requestId,
    );
  logGatewayEvent("sandbox_restore", env, {
    sandbox_id: id,
    request_id: requestId,
  });
  return json({
    ok: true,
    sandbox_id: id,
    restore: restored,
    request_id: requestId,
    ...versionMetadata(env),
  });
}

async function keepalive<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
  requestId: string,
): Promise<Response> {
  const body = await readJsonObject(request);
  const keepAlive = body.keep_alive === true;
  await deps.getSandbox(env, id, { keepAlive }).setKeepAlive?.(keepAlive);
  logGatewayEvent("sandbox_keepalive", env, {
    sandbox_id: id,
    request_id: requestId,
    keep_alive: keepAlive,
  });
  return json({
    ok: true,
    sandbox_id: id,
    keep_alive: keepAlive,
    request_id: requestId,
    ...versionMetadata(env),
  });
}

async function destroy<EnvType extends GatewayEnv>(
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
): Promise<Response> {
  await deps.getSandbox(env, id).destroy();
  logGatewayEvent("sandbox_destroy", env, { sandbox_id: id });
  return json({ ok: true, sandbox_id: id, ...versionMetadata(env) });
}

function connect<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
): Promise<Response> {
  logGatewayEvent("sandbox_connect", env, { sandbox_id: id });
  return deps
    .getSandbox(env, id)
    .wsConnect(connectorConnectRequest(request), 8080);
}

async function proxy<EnvType extends GatewayEnv>(
  request: Request,
  env: EnvType,
  deps: GatewayDeps<EnvType>,
  id: string,
  suffix: string,
): Promise<Response> {
  const diagnosticPath = proxyDiagnosticPath(suffix);
  if (!diagnosticPath) {
    return Promise.resolve(
      errorJson(
        "proxy_path_forbidden",
        403,
        "proxy is limited to diagnostic endpoints",
      ),
    );
  }
  const source = new URL(request.url);
  const target = new URL(`http://localhost:8080${diagnosticPath}`);
  target.search = source.search;
  const response = await deps
    .getSandbox(env, id)
    .containerFetch(
      new Request(target, stripControlPlaneRequestInit(request)),
      8080,
    );
  const headers = new Headers(response.headers);
  headers.set("x-salix-container-response", "1");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function proxyDiagnosticPath(suffix: string): string | undefined {
  const raw = suffix.slice("/proxy/".length);
  if (
    !raw ||
    raw.includes("%2e") ||
    raw.includes("%2E") ||
    raw.includes("%2f") ||
    raw.includes("%2F") ||
    raw.includes("%5c") ||
    raw.includes("%5C") ||
    raw.includes("\\")
  ) {
    return undefined;
  }
  const segments = raw.split("/");
  if (
    segments.some(
      (segment) => segment === "." || segment === ".." || segment === "",
    )
  )
    return undefined;
  const rawPath = `/${segments.join("/")}`;
  if (rawPath === "/healthz" || rawPath === "/readyz" || rawPath === "/archive" || rawPath === "/archive/export")
    return rawPath;
  if (segments[0] === "diagnostics" && segments.length > 1) return rawPath;
  return undefined;
}

function stripControlPlane(request: Request): Request {
  return new Request(request, {
    headers: stripControlPlaneHeaders(request.headers),
  });
}

function connectorConnectRequest(request: Request): Request {
  return new Request(
    "http://localhost:8080/connect",
    stripControlPlaneRequestInit(request),
  );
}

function stripControlPlaneRequestInit(request: Request): RequestInit {
  const init: RequestInit = {
    method: request.method,
    headers: stripControlPlaneHeaders(request.headers),
    redirect: "manual",
  };
  if (request.method !== "GET" && request.method !== "HEAD")
    init.body = request.body;
  return init;
}

function versionMetadata(env: GatewayEnv) {
  return {
    worker_version_id: env.VERSION_METADATA?.id || "local",
    worker_version_tag: env.VERSION_METADATA?.tag || "local",
    worker_version_timestamp: env.VERSION_METADATA?.timestamp || null,
    gateway_build_id: env.GATEWAY_BUILD_ID || "dev",
    connector_image_version: env.CONNECTOR_IMAGE_VERSION || "dev",
  };
}

function logGatewayEvent(
  event: string,
  env: GatewayEnv,
  fields: Record<string, unknown>,
) {
  console.log(JSON.stringify({ event, ...fields, ...versionMetadata(env) }));
}
