import { positiveInt, readBoundedBody, verifySignedRequest, type AuthEnv } from "./auth";

export type DispatchEnv = AuthEnv & {
  DISPATCHER: DispatchNamespace;
  MINIAPP_DISPATCH_MAX_BODY_BYTES?: string;
  VERSION_METADATA?: WorkerVersionMetadata;
};

/** Limits for every app request (design §8, "Resource abuse"). */
export const APP_LIMITS = { cpuMs: 50, subRequests: 50 } as const;

const ROUTE_PREFIX = "/internal/v1/apps/";
// Only Version scripts are callable. `app-<slug>-data` (the storage script) is not.
const SCRIPT = /^app-[a-z0-9]{1,40}-v[1-9][0-9]{0,8}$/;
const APP_METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE"]);
const HOST = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const MAX_EGRESS_HOSTS = 20;
// Matches the server's runtime route limit (≤ 1 MiB body), with room for framing.
const DEFAULT_MAX_BODY_BYTES = 1024 * 1024;
// The host part of the URL the app script sees. The script routes on the path.
const APP_ORIGIN = "https://app.invalid";

export function createDispatch<EnvType extends DispatchEnv>() {
  return {
    async fetch(request: Request, env: EnvType): Promise<Response> {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({ ok: true, version: env.VERSION_METADATA?.id ?? null });
      }
      if (!url.pathname.startsWith(ROUTE_PREFIX)) return notFound();

      const body = await readBoundedBody(
        request,
        positiveInt(env.MINIAPP_DISPATCH_MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES),
      );
      if (!body) return error("body_too_large", 413, "request body too large");

      const auth = await verifySignedRequest(request, body, env);
      if (!auth.ok) {
        console.warn(JSON.stringify({ event: "miniapp_dispatch_refused", reason: auth.reason }));
        return notFound();
      }

      const rest = url.pathname.slice(ROUTE_PREFIX.length);
      const slash = rest.indexOf("/");
      const script = slash < 0 ? rest : rest.slice(0, slash);
      const appPath = slash < 0 ? "/" : rest.slice(slash);
      if (!SCRIPT.test(script)) return notFound();

      const method = (request.headers.get("x-comma-app-method") || request.method).toUpperCase();
      if (!APP_METHODS.has(method)) return error("invalid", 400, "unsupported app method");
      const egress = parseEgress(request.headers.get("x-comma-app-egress"));
      if (!egress) return error("invalid", 400, "invalid egress list");

      const forwarded = new Request(`${APP_ORIGIN}${appPath}${url.search}`, {
        method,
        headers: appHeaders(request.headers),
        body: method === "GET" || method === "DELETE" || body.byteLength === 0 ? undefined : body,
      });

      try {
        const worker = env.DISPATCHER.get(script, {}, {
          limits: { ...APP_LIMITS },
          outbound: { egress, app: appSlug(script) },
        });
        return await worker.fetch(forwarded);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        if (message.startsWith("Worker not found")) return notFound();
        console.warn(JSON.stringify({ event: "miniapp_app_error", script, request_id: auth.requestId, message: message.slice(0, 500) }));
        return error("app_error", 502, message.slice(0, 1000) || "app error");
      }
    },
  };
}

/** Headers the app sees: the request's own headers without the signing and routing ones. */
export function appHeaders(incoming: Headers): Headers {
  const headers = new Headers();
  for (const [name, value] of incoming.entries()) {
    const lower = name.toLowerCase();
    if (lower.startsWith("x-salix-") || lower.startsWith("x-comma-") || lower.startsWith("cf-")) continue;
    if (lower === "host" || lower === "content-length" || lower === "authorization" || lower === "cookie") continue;
    headers.set(name, value);
  }
  for (const name of ["x-comma-app-version", "x-comma-viewer"]) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

/** The manifest's egress hosts, as the server sends them: comma-separated host names. */
export function parseEgress(value: string | null): string[] | undefined {
  if (!value || value.trim() === "") return [];
  const hosts = value.split(",").map((h) => h.trim().toLowerCase()).filter((h) => h !== "");
  if (hosts.length > MAX_EGRESS_HOSTS) return undefined;
  return hosts.every((h) => HOST.test(h)) ? [...new Set(hosts)] : undefined;
}

function appSlug(script: string): string {
  return script.slice("app-".length, script.lastIndexOf("-v"));
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

function error(code: string, status: number, message: string): Response {
  return json({ error: code, message }, status);
}

function notFound(): Response {
  return json({ error: "not_found" }, 404);
}
