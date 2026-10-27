// Request signing shared with the Comma server. The canonical string is the
// salix-vm-gateway scheme (systems/cloudflare/salix-vm-gateway/src/auth.ts):
// [METHOD, pathname+search, timestamp, nonce, sha256hex(body)].join("\n"),
// HMAC-SHA256 with the shared secret, sent as `sha256=<hex>`.

export type AuthEnv = {
  MINIAPP_DISPATCH_SECRET?: string;
  MINIAPP_DISPATCH_MAX_SKEW_SECONDS?: string;
  ReplayGuard?: DurableObjectNamespace;
};

export type AuthResult =
  | { ok: true; requestId: string }
  | { ok: false; reason: string };

const DEFAULT_MAX_SKEW_SECONDS = 300;

/**
 * Verifies the signature of a request whose body the caller already read.
 * Every refusal has a reason for the log; the caller answers 404 for all of them.
 */
export async function verifySignedRequest(
  request: Request,
  body: ArrayBuffer,
  env: AuthEnv,
): Promise<AuthResult> {
  const secret = env.MINIAPP_DISPATCH_SECRET;
  if (!secret) return { ok: false, reason: "auth_not_configured" };

  const requestId = request.headers.get("x-salix-request-id") || crypto.randomUUID();
  const timestamp = request.headers.get("x-salix-timestamp");
  const nonce = request.headers.get("x-salix-nonce");
  const signature = request.headers.get("x-salix-signature");
  if (!timestamp || !nonce || !signature) {
    return { ok: false, reason: "missing_signature" };
  }

  const skew = positiveInt(env.MINIAPP_DISPATCH_MAX_SKEW_SECONDS, DEFAULT_MAX_SKEW_SECONDS);
  if (!freshTimestamp(timestamp, skew)) return { ok: false, reason: "stale_signature" };

  const url = new URL(request.url);
  const expected = await signRequest(
    secret,
    request.method,
    `${url.pathname}${url.search}`,
    timestamp,
    nonce,
    body,
  );
  if (!timingSafeEqual(signature, expected)) return { ok: false, reason: "bad_signature" };

  // Without the replay guard a captured request could run again: fail closed.
  if (!env.ReplayGuard) return { ok: false, reason: "replay_guard_not_configured" };
  const guard = env.ReplayGuard.get(env.ReplayGuard.idFromName(nonce.slice(0, 64)));
  const replay = await guard.fetch("https://replay-guard/internal/claim", {
    method: "POST",
    body: JSON.stringify({ nonce, timestamp }),
  });
  if (!replay.ok) return { ok: false, reason: "replayed_signature" };

  return { ok: true, requestId };
}

/** Reads at most `maxBytes` of the body; `undefined` when it is larger. */
export async function readBoundedBody(
  request: Request,
  maxBytes: number,
): Promise<ArrayBuffer | undefined> {
  if (request.method === "GET" || request.method === "HEAD") return new ArrayBuffer(0);
  const length = request.headers.get("content-length");
  if (length && Number.parseInt(length, 10) > maxBytes) return undefined;
  const reader = request.body?.getReader();
  if (!reader) return new ArrayBuffer(0);
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      return undefined;
    }
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
  const bodyHash = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", body)));
  const canonical = [method.toUpperCase(), path, timestamp, nonce, bodyHash].join("\n");
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical));
  return `sha256=${hex(new Uint8Array(sig))}`;
}

export function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function freshTimestamp(value: string, maxSkewSeconds: number): boolean {
  if (!/^\d{1,12}$/.test(value)) return false;
  const parsed = Number.parseInt(value, 10);
  return Math.abs(Math.floor(Date.now() / 1000) - parsed) <= maxSkewSeconds;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(left: string, right: string): boolean {
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
