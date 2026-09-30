import { errorJson } from "./json";

export type AuthEnv = {
  SALIX_VM_GATEWAY_SECRET?: string;
  SALIX_VM_GATEWAY_MAX_SKEW_SECONDS?: string;
  SALIX_VM_GATEWAY_MAX_BODY_BYTES?: string;
  ReplayGuard?: DurableObjectNamespace;
};

export type AuthResult =
  | { ok: true; requestId: string }
  | { ok: false; response: Response };

const SIGNED_HEADERS = [
  "x-salix-request-id",
  "x-salix-timestamp",
  "x-salix-nonce",
];
const DEFAULT_MAX_BODY_BYTES = 16 * 1024 * 1024;

export async function authorize(
  request: Request,
  env: AuthEnv,
): Promise<AuthResult> {
  const requestId =
    request.headers.get("x-salix-request-id") || crypto.randomUUID();
  const secret = env.SALIX_VM_GATEWAY_SECRET;
  if (!secret) {
    return {
      ok: false,
      response: errorJson(
        "auth_not_configured",
        503,
        "gateway auth is not configured",
        requestId,
      ),
    };
  }

  const timestamp = request.headers.get("x-salix-timestamp");
  const nonce = request.headers.get("x-salix-nonce");
  const signature = request.headers.get("x-salix-signature");
  if (!timestamp || !nonce || !signature) {
    return {
      ok: false,
      response: errorJson(
        "missing_signature",
        401,
        "missing signature headers",
        requestId,
      ),
    };
  }

  const skewSeconds = Number.parseInt(
    env.SALIX_VM_GATEWAY_MAX_SKEW_SECONDS || "300",
    10,
  );
  if (
    !freshTimestamp(timestamp, Number.isFinite(skewSeconds) ? skewSeconds : 300)
  ) {
    return {
      ok: false,
      response: errorJson(
        "stale_signature",
        401,
        "stale signature timestamp",
        requestId,
      ),
    };
  }

  const maxBodyBytes = positiveInt(
    env.SALIX_VM_GATEWAY_MAX_BODY_BYTES,
    DEFAULT_MAX_BODY_BYTES,
  );
  const body = await readBoundedBody(request, maxBodyBytes);
  if (!body) {
    return {
      ok: false,
      response: errorJson(
        "body_too_large",
        413,
        "request body too large",
        requestId,
      ),
    };
  }
  const url = new URL(request.url);
  const expected = await signRequest(
    secret,
    request.method,
    `${url.pathname}${url.search}`,
    timestamp,
    nonce,
    body,
  );
  if (!(await timingSafeEqual(signature, expected))) {
    return {
      ok: false,
      response: errorJson("bad_signature", 401, "invalid signature", requestId),
    };
  }

  if (env.ReplayGuard) {
    const guardId = env.ReplayGuard.idFromName(nonce.slice(0, 64));
    const guard = env.ReplayGuard.get(guardId);
    const replay = await guard.fetch("https://replay-guard/internal/claim", {
      method: "POST",
      body: JSON.stringify({ nonce, timestamp }),
    });
    if (!replay.ok) {
      return {
        ok: false,
        response: errorJson(
          "replayed_signature",
          401,
          "signature nonce was already used",
          requestId,
        ),
      };
    }
  }

  return { ok: true, requestId };
}

async function readBoundedBody(
  request: Request,
  maxBytes: number,
): Promise<ArrayBuffer | undefined> {
  if (request.method === "GET" || request.method === "HEAD")
    return new ArrayBuffer(0);
  const length = request.headers.get("content-length");
  if (length && Number.parseInt(length, 10) > maxBytes) return undefined;
  const reader = request.clone().body?.getReader();
  if (!reader) return new ArrayBuffer(0);
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) return undefined;
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body.buffer;
}

export async function signRequest(
  secret: string,
  method: string,
  path: string,
  timestamp: string,
  nonce: string,
  body: ArrayBuffer,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bodyHash = await sha256Hex(body);
  const canonical = [
    method.toUpperCase(),
    path,
    timestamp,
    nonce,
    bodyHash,
  ].join("\n");
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(canonical),
  );
  return `sha256=${hex(new Uint8Array(sig))}`;
}

export function stripControlPlaneHeaders(headers: Headers): Headers {
  const out = new Headers(headers);
  out.delete("authorization");
  out.delete("cookie");
  out.delete("set-cookie");
  out.delete("x-salix-signature");
  for (const header of SIGNED_HEADERS) out.delete(header);
  return out;
}

function freshTimestamp(value: string, maxSkewSeconds: number): boolean {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return false;
  return Math.abs(Math.floor(Date.now() / 1000) - parsed) <= maxSkewSeconds;
}

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function sha256Hex(body: ArrayBuffer): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", body)));
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function timingSafeEqual(left: string, right: string): Promise<boolean> {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  const max = Math.max(a.length, b.length);
  const paddedA = new Uint8Array(max);
  const paddedB = new Uint8Array(max);
  paddedA.set(a);
  paddedB.set(b);
  let diff = a.length ^ b.length;
  for (let i = 0; i < max; i += 1) diff |= paddedA[i] ^ paddedB[i];
  return diff === 0;
}
