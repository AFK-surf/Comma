// Outbound Worker of the Mini App dispatch namespace. Every `fetch` that an app
// script makes arrives here (design §6.3, §8 "Reach internal services from a
// backend"). The dispatch Worker passes two parameters per request:
//   egress: string[]  the Version manifest's `backend.egress` hosts
//   app:    string    the app slug, the rate-limit key
// A request leaves only when it is https on the default port, its host is in
// `egress`, and its host is not a Comma host, an IP literal or a local name.

export type OutboundEnv = {
  egress?: unknown;
  app?: unknown;
  /** Extra blocked host suffixes, comma-separated (for example "comma.dev,internal.example"). */
  MINIAPP_BLOCKED_HOSTS?: string;
  /** Per-app outbound budget. See wrangler.jsonc `ratelimits`. */
  EGRESS_LIMITER?: RateLimit;
};

/** Comma hosts: an app may never call them, whatever its manifest says. */
export const COMMA_HOST_SUFFIXES = ["comma.surf", "afk.surf"];
// Names that resolve to this machine or a private network, never a public API.
const LOCAL_SUFFIXES = ["localhost", "local", "internal", "intranet", "lan", "home.arpa", "localdomain", "invalid", "test", "example", "onion"];

export type EgressDecision = { ok: true } | { ok: false; reason: string };

export function egressDecision(target: URL, egress: unknown, extraBlocked: string | undefined): EgressDecision {
  if (target.protocol !== "https:") return { ok: false, reason: "only https is allowed" };
  if (target.port !== "") return { ok: false, reason: "only the default https port is allowed" };
  if (target.username !== "" || target.password !== "") return { ok: false, reason: "credentials in the URL are not allowed" };
  const host = target.hostname.toLowerCase().replace(/\.$/, "");
  if (isIpLiteral(host)) return { ok: false, reason: "IP addresses are not allowed" };
  if (!host.includes(".")) return { ok: false, reason: "local host names are not allowed" };
  const blocked = [...COMMA_HOST_SUFFIXES, ...LOCAL_SUFFIXES, ...splitList(extraBlocked)];
  if (blocked.some((suffix) => host === suffix || host.endsWith(`.${suffix}`))) {
    return { ok: false, reason: `host ${host} is blocked` };
  }
  const allowed = Array.isArray(egress)
    ? egress.filter((h): h is string => typeof h === "string").map((h) => h.toLowerCase())
    : typeof egress === "string" ? splitList(egress) : [];
  if (!allowed.includes(host)) return { ok: false, reason: `host ${host} is not in the app's egress list` };
  return { ok: true };
}

export default {
  async fetch(request: Request, env: OutboundEnv): Promise<Response> {
    let target: URL;
    try {
      target = new URL(request.url);
    } catch {
      return refuse(403, "egress_blocked", "invalid URL");
    }
    const decision = egressDecision(target, env.egress, env.MINIAPP_BLOCKED_HOSTS);
    if (!decision.ok) return refuse(403, "egress_blocked", decision.reason);

    const app = typeof env.app === "string" && env.app !== "" ? env.app : "unknown";
    if (env.EGRESS_LIMITER) {
      const { success } = await env.EGRESS_LIMITER.limit({ key: app });
      if (!success) return refuse(429, "rate_limited", "outbound request rate limit reached");
    }

    // Redirects come back to the app script: a followed redirect would leave
    // through this Worker without the checks above.
    return fetch(new Request(request, { redirect: "manual" }));
  },
};

function isIpLiteral(host: string): boolean {
  // The URL parser normalizes IPv4 forms (decimal, hex, octal) to dotted quads
  // and keeps IPv6 in brackets.
  return host.startsWith("[") || /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || /^[0-9.]+$/.test(host);
}

function splitList(value: string | undefined): string[] {
  return (value || "").split(",").map((h) => h.trim().toLowerCase().replace(/^\*?\./, "")).filter((h) => h !== "");
}

function refuse(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
