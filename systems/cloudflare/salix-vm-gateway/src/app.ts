import { authorize, type AuthEnv } from "./auth";
import { sandboxIdFromPath, parseSandboxId } from "./ids";
import { errorJson, json, readJsonObject } from "./json";
import { ControlError, parseControlPermit, requestControlPermit, type ControlPermit } from "./control";
import type { ManagedSandbox, ControlObservation, StationEnv } from "./managed_sandbox";

export type SandboxHandle = {
  salixObserve(): Promise<ControlObservation> | ControlObservation;
  salixOpen(permit: ControlPermit): Promise<ControlObservation>;
  salixSeal(permit: ControlPermit): Promise<ControlObservation>;
  salixEnsure(permit: ControlPermit, keepAlive: boolean, station: StationEnv): Promise<ControlObservation>;
  salixKeepAlive(permit: ControlPermit, keepAlive: boolean): Promise<void>;
  salixDestroy(permit: ControlPermit, discard?: boolean): Promise<ControlObservation>;
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
    // uses the station's archive (exported over its connection, restored by
    // the Container's start) and must not fall back to that carrier.
    return errorJson("provider_archive_required", 409);
  }

  const permit = body?.control ? parseControlPermit(body.control) : requestControlPermit(request);
  switch (parsed.suffix) {
    case "/ensure": {
      if (request.method !== "POST") return errorJson("method_not_allowed", 405);
      body ??= await readJsonObject(request);
      const station = stationEnv(body.station);
      if (!station) return errorJson("invalid_station", 400, "station needs its server and credential, and a restore Salix encoded", requestId);
      const observation = await sandbox().salixEnsure(permit, body.keep_alive === true, station);
      logGatewayEvent("sandbox_ensure", env, { sandbox_id: parsed.id, request_id: requestId, running: observation.running, restore: station.SALIX_RESTORE_ARCHIVE !== undefined });
      // Issuing the one native start completes the command; the station connects once it runs.
      return result({ status: "started", running: observation.running });
    }
    case "/status": {
      if (request.method !== "GET" && request.method !== "POST") return errorJson("method_not_allowed", 405);
      const observation = await sandbox().salixObserve();
      return result({ status: observation.running ? "running" : "stopped" });
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
      body ??= await readJsonObject(request);
      const observation = await sandbox().salixDestroy(permit, body.discard === true);
      logGatewayEvent("sandbox_destroy", env, { sandbox_id: parsed.id, request_id: requestId });
      return result({ ...observation });
    }
    default:
      return errorJson("not_found", 404);
  }
}

/** The most a restore may be as one environment string: it is the same small size for every archive. */
const RESTORE_VALUE_LIMIT = 8 * 1024;

/**
 * What the Container starts its station with, from Salix: the station's server (a wss URL, or ws to a loopback address
 * in tests) and its credential, and, when the disk is to be an archive, that archive (`restore`: Salix's encoding of
 * one short-lived signed read URL, of the manifest of its parts; opaque here), which the image unpacks before it
 * starts the station.
 */
function stationEnv(value: unknown): StationEnv | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const { server, credential, restore } = value as Record<string, unknown>;
  if (typeof server !== "string" || typeof credential !== "string") return null;
  if (credential.length < 1 || credential.length > 4096 || /[\x00-\x20\x7f]/.test(credential)) return null;
  let url: URL;
  try { url = new URL(server); } catch { return null; }
  if (url.protocol !== "wss:" && !(url.protocol === "ws:" && ["127.0.0.1", "localhost"].includes(url.hostname))) return null;
  if (restore === undefined) return { SALIX_SERVER: server, SALIX_WORKLOAD_CREDENTIAL: credential };
  if (typeof restore !== "string" || restore.length < 1 || restore.length > RESTORE_VALUE_LIMIT || !/^[A-Za-z0-9+/]+={0,2}$/.test(restore)) return null;
  return { SALIX_SERVER: server, SALIX_WORKLOAD_CREDENTIAL: credential, SALIX_RESTORE_ARCHIVE: restore };
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
