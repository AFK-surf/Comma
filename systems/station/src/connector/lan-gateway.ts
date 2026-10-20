// HTTP requests (http_request, and lan_http_request from a gateway device with tighter limits) and UDP request/reply
// (udp_request): bounded in bytes, time and responses, never following redirects.
import { createSocket } from "node:dgram";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { Duration, Effect } from "effect";
import { defaultString, intParam, mapParam, stringFromAny, stringParam } from "./message.ts";

export const LAN_GATEWAY_MAX_BYTES = 64 * 1024;
export const LAN_GATEWAY_MAX_TIMEOUT_SECONDS = 30;
export const LAN_GATEWAY_DEFAULT_TIMEOUT = Duration.seconds(10);
export const LAN_UDP_MAX_PAYLOAD_BYTES = 1472;
export const LAN_UDP_MAX_RESPONSES = 16;
export const LAN_UDP_MAX_RESPONSE_BYTES = 64 * 1024;
export const LAN_UDP_DEFAULT_TIMEOUT_MS = 2_000;
export const LAN_UDP_MAX_TIMEOUT_MS = 10_000;
export const HTTP_REQUEST_MAX_BYTES = 10 * 1024 * 1024;

export function lanGatewayCapability() {
  return { methods: ["lan_http_request", "lan_tcp_dial", "udp_request"], max_bytes: LAN_GATEWAY_MAX_BYTES, max_timeout_seconds: LAN_GATEWAY_MAX_TIMEOUT_SECONDS };
}

export type HttpLimits = { defaultTimeout: Duration.Duration; maxTimeout?: Duration.Duration; maxBytes: number };

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** Go's canonical header key form (Content-Type), as the Go connector reported response headers. */
const canonicalHeaderKey = (key: string) => key.split("-").map((part) => (part ? part[0].toUpperCase() + part.slice(1).toLowerCase() : part)).join("-");

export function performHttpRequest(params: Record<string, unknown>, limits: HttpLimits): Effect.Effect<Record<string, any>, Error> {
  return Effect.gen(function* () {
    const method = defaultString(stringParam(params, "method"), "POST").toUpperCase();
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(method)) return yield* Effect.fail(new Error(`unsupported HTTP method: ${method}`));
    const rawUrl = stringParam(params, "url");
    if (!rawUrl) return yield* Effect.fail(new Error("'url' is required"));
    let parsed: URL;
    try {
      parsed = new URL(rawUrl);
    } catch {
      return yield* Effect.fail(new Error("'url' must be an absolute http or https URL"));
    }
    if (!parsed.host) return yield* Effect.fail(new Error("'url' must be an absolute http or https URL"));
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return yield* Effect.fail(new Error("'url' must use http or https"));
    let timeout = Duration.seconds(intParam(params, "timeout_seconds", 0));
    if (Duration.toMillis(timeout) <= 0) timeout = limits.defaultTimeout;
    if (limits.maxTimeout && Duration.isGreaterThan(timeout, limits.maxTimeout)) timeout = limits.maxTimeout;
    const body = stringParam(params, "body");
    const headers = new Headers();
    for (const [key, value] of Object.entries(mapParam(params, "headers"))) if (key) headers.set(key, stringFromAny(value));
    if (body && !headers.has("content-type")) headers.set("content-type", "application/json");
    let limit = intParam(params, "max_bytes", limits.maxBytes);
    if (limit <= 0 || limit > limits.maxBytes) limit = limits.maxBytes;
    const outcome = yield* Effect.tryPromise({
      try: async (signal) => {
        const response = await fetch(rawUrl, { method, headers, body: method === "GET" || method === "HEAD" ? undefined : body, redirect: "manual", signal });
        const chunks: Buffer[] = [];
        let total = 0;
        const reader = response.body?.getReader();
        while (reader && total <= limit) {
          const { value, done } = await reader.read();
          if (done) break;
          chunks.push(Buffer.from(value));
          total += value.length;
        }
        await reader?.cancel().catch(() => {});
        const raw = Buffer.concat(chunks);
        const truncated = raw.length > limit;
        const kept = truncated ? raw.subarray(0, limit) : raw;
        const responseHeaders: Record<string, string[]> = {};
        response.headers.forEach((value, key) => {
          (responseHeaders[canonicalHeaderKey(key)] ??= []).push(value);
        });
        return { status: response.status, headers: responseHeaders, body: kept.toString("utf8"), truncated, final_url: rawUrl, method, body_bytes: kept.length };
      },
      catch: toError,
    }).pipe(Effect.timeoutOption(timeout));
    if (outcome._tag === "None") return yield* Effect.fail(new Error(`context deadline exceeded (Client.Timeout exceeded after ${Duration.toSeconds(timeout)}s)`));
    return outcome.value;
  });
}

export const httpRequest = (params: Record<string, unknown>) => performHttpRequest(params, { defaultTimeout: Duration.seconds(120), maxBytes: HTTP_REQUEST_MAX_BYTES });

export const lanHttpRequest = (params: Record<string, unknown>) =>
  performHttpRequest(params, { defaultTimeout: LAN_GATEWAY_DEFAULT_TIMEOUT, maxTimeout: Duration.seconds(LAN_GATEWAY_MAX_TIMEOUT_SECONDS), maxBytes: LAN_GATEWAY_MAX_BYTES });

/** Sends one datagram and collects replies from the destination host until the count, size or time runs out. */
export function udpRequest(params: Record<string, unknown>): Effect.Effect<{ responses: Array<{ from: string; payload_b64: string }>; timed_out: boolean }, Error> {
  return Effect.gen(function* () {
    const host = stringParam(params, "host");
    if (!host) return yield* Effect.fail(new Error("'host' is required"));
    const port = intParam(params, "port", 0);
    if (port < 1 || port > 65535) return yield* Effect.fail(new Error("'port' must be between 1 and 65535"));
    const encoded = stringParam(params, "payload_b64");
    const payload = Buffer.from(encoded, "base64");
    if (payload.length === 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded) || encoded.length % 4 !== 0) return yield* Effect.fail(new Error("'payload_b64' must be non-empty base64"));
    if (payload.length > LAN_UDP_MAX_PAYLOAD_BYTES) return yield* Effect.fail(new Error("'payload_b64' exceeds 1472 bytes"));
    let timeoutMs = intParam(params, "timeout_ms", 0);
    if (timeoutMs <= 0) timeoutMs = LAN_UDP_DEFAULT_TIMEOUT_MS;
    timeoutMs = Math.min(timeoutMs, LAN_UDP_MAX_TIMEOUT_MS);
    let maxResponses = intParam(params, "max_responses", LAN_UDP_MAX_RESPONSES);
    if (maxResponses <= 0 || maxResponses > LAN_UDP_MAX_RESPONSES) maxResponses = LAN_UDP_MAX_RESPONSES;
    const address = isIP(host) ? host : (yield* Effect.tryPromise({ try: () => lookup(host), catch: toError })).address;
    const family = isIP(address) === 6 ? "udp6" : "udp4";
    const responses: Array<{ from: string; payload_b64: string }> = [];
    let total = 0;
    const socket = createSocket(family);
    const full = yield* Effect.callback<boolean, Error>((resume) => {
      socket.on("error", (error) => resume(Effect.fail(error)));
      socket.on("message", (message, from) => {
        if (from.address !== address) return;
        if (total + message.length > LAN_UDP_MAX_RESPONSE_BYTES) return resume(Effect.succeed(true));
        total += message.length;
        const fromText = family === "udp6" ? `[${from.address}]:${from.port}` : `${from.address}:${from.port}`;
        responses.push({ from: fromText, payload_b64: message.toString("base64") });
        if (responses.length >= maxResponses) resume(Effect.succeed(true));
      });
      socket.send(payload, port, address, (error) => error && resume(Effect.fail(error)));
    }).pipe(
      Effect.timeoutOption(Duration.millis(timeoutMs)),
      Effect.ensuring(Effect.sync(() => socket.close())),
    );
    return { responses, timed_out: full._tag === "None" };
  });
}
