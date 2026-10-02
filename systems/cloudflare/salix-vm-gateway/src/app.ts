import { authorize, stripControlPlaneHeaders, type AuthEnv } from "./auth";
import { sandboxIdFromPath, parseSandboxId } from "./ids";
import { errorJson, json, readJsonObject } from "./json";
import { ControlError, parseControlPermit, requestControlPermit, type ControlPermit, type ControlAction } from "./control";
import type { ManagedSandbox, ControlObservation } from "./managed_sandbox";

export type SandboxHandle = {
  salixObserve(): Promise<ControlObservation> | ControlObservation;
  salixOpen(permit: ControlPermit): Promise<ControlObservation>;
  salixSeal(permit: ControlPermit): Promise<ControlObservation>;
  salixEnsure(permit: ControlPermit, keepAlive: boolean): Promise<Response>;
  salixStatus(permit: ControlPermit): Promise<Response>;
  salixReceipt(permit: ControlPermit, operation: string): Promise<Response>;
  salixForward(permit: ControlPermit, request: Request, action: ControlAction | "observe", archiveOperation?: string): Promise<Response>;
  salixKeepAlive(permit: ControlPermit, keepAlive: boolean): Promise<void>;
  salixDestroy(permit: ControlPermit): Promise<ControlObservation>;
  fetch(request: Request): Promise<Response>;
};

export type GatewayEnv = AuthEnv & {
  Sandbox: DurableObjectNamespace<ManagedSandbox>;
  SandboxStandard1: DurableObjectNamespace<ManagedSandbox>;
  VERSION_METADATA?: WorkerVersionMetadata;
  GATEWAY_BUILD_ID?: string;
  CONNECTOR_IMAGE_VERSION?: string;
};

type GatewayDeps<EnvType extends GatewayEnv> = {
  getSandbox(env: EnvType, id: string, profile: "cf-standard-1" | "cf-standard-2"): SandboxHandle;
};

export function createGateway<EnvType extends GatewayEnv>(deps: GatewayDeps<EnvType>) {
  return {
    async fetch(request: Request, env: EnvType): Promise<Response> {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz") return json({ ok: true, ...versionMetadata(env) });
      if (!url.pathname.startsWith("/internal/v1/sandboxes") && !url.pathname.startsWith("/internal/v1/profiles/")) return errorJson("not_found", 404);
      const auth = await authorize(request, env);
      if (!auth.ok) return auth.response;
      try {
        return await route(request, env, deps, auth.requestId);
      } catch (error) {
        if (error instanceof ControlError) return errorJson(error.code, error.status, error.message, auth.requestId);
        // RPC preserves Error.message, but does not preserve custom prototypes.
        const message = error instanceof Error ? error.message : "gateway error";
        if (/^(control_[a-z_]+|stale_control_[a-z_]+|container_(not_running|start_unsettled|destroy_unsettled|unavailable))$/.test(message)) {
          return errorJson(message, message.startsWith("container_") ? 503 : 409, message, auth.requestId);
        }
        return errorJson("gateway_error", 500, message, auth.requestId);
      }
    },
  };
}

async function route<EnvType extends GatewayEnv>(request: Request, env: EnvType, deps: GatewayDeps<EnvType>, requestId: string): Promise<Response> {
  const url = new URL(request.url);
  const prefix = "/internal/v1/profiles/cf-standard-1";
  const profile = url.pathname.startsWith(prefix + "/") ? "cf-standard-1" : "cf-standard-2";
  const pathname = profile === "cf-standard-1" ? "/internal/v1" + url.pathname.slice(prefix.length) : url.pathname;
  let body: Record<string, unknown> | undefined;
  let parsed = sandboxIdFromPath(pathname);
  if (pathname === "/internal/v1/sandboxes" && request.method === "POST") {
    body = await readJsonObject(request);
    const id = parseSandboxId(typeof body.sandbox_id === "string" ? body.sandbox_id : undefined);
    if (!id) return errorJson("invalid_sandbox_id", 400);
    parsed = { id, suffix: "/ensure" };
  }
  if (!parsed) return errorJson("invalid_sandbox_id", 400, "invalid sandbox id", requestId);
  const sandbox = () => deps.getSandbox(env, parsed.id, profile);
  const result = (fields: Record<string, unknown>) => json({ ok: true, sandbox_id: parsed.id, request_id: requestId, ...fields, ...versionMetadata(env) });

  if (parsed.suffix === "/control") {
    if (request.method === "GET") return result({ ...(await sandbox().salixObserve()) });
    if (request.method !== "POST") return errorJson("method_not_allowed", 405);
    const controlBody = await readJsonObject(request);
    const permit = parseControlPermit(controlBody.control);
    if (controlBody.action === "open") return result({ ...(await sandbox().salixOpen(permit)) });
    if (controlBody.action === "seal") return result({ ...(await sandbox().salixSeal(permit)) });
    return errorJson("invalid_control_action", 400);
  }

  if (parsed.suffix === "/checkpoint" || parsed.suffix === "/restore") {
    // SDK backups are a separate auto-start carrier. Managed Group recovery
    // uses Connector archive/import and must not fall back to that carrier.
    return errorJson("provider_archive_required", 409);
  }

  if (parsed.suffix.startsWith("/proxy/") && !proxyDiagnosticPath(parsed.suffix)) return errorJson("proxy_path_forbidden", 403);
  const permit = body?.control ? parseControlPermit(body.control) : requestControlPermit(request);
  switch (parsed.suffix) {
    case "/ensure": {
      if (request.method !== "POST") return errorJson("method_not_allowed", 405);
      body ??= await readJsonObject(request);
      const response = await sandbox().salixEnsure(permit, body.keep_alive === true);
      if (!response.ok) return response;
      logGatewayEvent("sandbox_ensure", env, { sandbox_id: parsed.id, request_id: requestId, ready_status: response.status });
      return result({ status: "ready" });
    }
    case "/status": {
      if (request.method !== "GET" && request.method !== "POST") return errorJson("method_not_allowed", 405);
      const response = await sandbox().salixStatus(permit);
      logGatewayEvent("sandbox_status", env, { sandbox_id: parsed.id, request_id: requestId, health_status: response.status });
      return result({ status: response.ok ? "ready" : "starting", health_status: response.status });
    }
    case "/receipt": {
      if (request.method !== "GET") return errorJson("method_not_allowed", 405);
      return containerResponse(await sandbox().salixReceipt(permit, url.searchParams.get("operation") ?? ""));
    }
    case "/keepalive": {
      if (request.method !== "POST") return errorJson("method_not_allowed", 405);
      body ??= await readJsonObject(request);
      await sandbox().salixKeepAlive(permit, body.keep_alive === true);
      logGatewayEvent("sandbox_keepalive", env, { sandbox_id: parsed.id, request_id: requestId, keep_alive: body.keep_alive === true });
      return result({ keep_alive: body.keep_alive === true });
    }
    case "/destroy": {
      if (request.method !== "POST" && request.method !== "DELETE") return errorJson("method_not_allowed", 405);
      const observation = await sandbox().salixDestroy(permit);
      logGatewayEvent("sandbox_destroy", env, { sandbox_id: parsed.id, request_id: requestId });
      return result({ ...observation });
    }
    case "/connect": {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return errorJson("upgrade_required", 426, "websocket upgrade required", requestId, { upgrade: "websocket" });
      const target = new URL("http://localhost:8080/connect");
      target.searchParams.set("salix_control", JSON.stringify(permit));
      if (url.searchParams.get("archive_repair") === "true") target.searchParams.set("archive_repair", "true");
      logGatewayEvent("sandbox_connect", env, { sandbox_id: parsed.id, request_id: requestId });
      return sandbox().fetch(new Request(target, forwardInit(request)));
    }
    default: {
      if (!parsed.suffix.startsWith("/proxy/")) return errorJson("not_found", 404);
      const path = proxyDiagnosticPath(parsed.suffix)!;
      const target = new URL(`http://localhost:8080${path}`);
      target.search = url.search;
      target.searchParams.delete("salix_control");
      let action: ControlAction | "observe" = "observe";
      let archiveOperation: string | undefined;
      if (path === "/archive" && request.method === "POST") {
        const importBody = await readJsonObject(request.clone());
        archiveOperation = typeof importBody.operation === "string" ? importBody.operation : undefined;
        action = importBody.action === "status" ? "observe" : "import";
      } else if (request.method !== "GET" && request.method !== "HEAD") {
        if (path === "/archive") action = "import";
        else if (path === "/archive/export") action = "export";
        else if (path === "/control" && request.method === "POST") action = "connector_control";
        else return errorJson("proxy_method_forbidden", 405);
      }
      return containerResponse(await sandbox().salixForward(permit, new Request(target, forwardInit(request)), action, archiveOperation));
    }
  }
}

function containerResponse(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("x-salix-container-response", "1");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

function proxyDiagnosticPath(suffix: string): string | undefined {
  const raw = suffix.slice("/proxy/".length);
  if (!raw || /%(2e|2f|5c)/i.test(raw) || raw.includes("\\")) return undefined;
  const segments = raw.split("/");
  if (segments.some((s) => s === "." || s === ".." || s === "")) return undefined;
  const path = `/${segments.join("/")}`;
  if (["/healthz", "/readyz", "/archive", "/archive/export", "/control"].includes(path)) return path;
  if (segments[0] === "diagnostics" && segments.length > 1) return path;
  return undefined;
}

function forwardInit(request: Request): RequestInit {
  return { method: request.method, headers: stripControlPlaneHeaders(request.headers), redirect: "manual", ...request.method !== "GET" && request.method !== "HEAD" && { body: request.body } };
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

function logGatewayEvent(event: string, env: GatewayEnv, fields: Record<string, unknown>) {
  try { console.log(JSON.stringify({ event, ...fields, ...versionMetadata(env) })); } catch { /* diagnostics cannot change the command */ }
}
