// What the web session lifecycle reads from the auth endpoints, and how it words their refusals. The answers are read
// as the page adapter read them: unknown fields are ignored (a newer server), and the Cookie transport never accepts
// a bearer in an answer.
import {
  guestPowMaxAttempts,
  hasLeadingZeroBits,
  type GuestPowSolution,
} from "@comma/session-contract";
import { Effect } from "effect";
import { z } from "zod";
import type { HostError } from "@comma/core-kernel";

/** An auth endpoint's answer: its status and its JSON body (undefined when it had none that parsed). */
export type AuthResponse = { ok: boolean; status: number; body: unknown };

const sessionUser = z.object({
  email: z.string().email(),
  id: z.string().min(1).max(256),
  // Older servers omit the kind; any value other than "guest" is registered.
  kind: z.string().max(64).nullable().optional(),
  name: z.string().min(1).max(512).nullable().optional(),
  status: z.string().min(1).max(64).nullable().optional(),
});

export const sessionProjection = z.object({
  expires_at: z.number().int().positive(),
  session_id: z.string().min(1).max(256),
  token: z.never().optional(),
  user: sessionUser,
});
export type SessionProjection = z.output<typeof sessionProjection>;

export const emailChallenge = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
});

export const googleAttempt = z.object({
  attempt_id: z.string().min(1).max(256),
  client_id: z.string().min(1).max(2_048),
  nonce: z.string().min(1).max(2_048),
  platform: z.literal("web"),
});

export const googleLinkChallenge = z.object({
  challenge_id: z.string().min(1).max(256),
  code: z.string().min(1).max(32).optional(),
  email: z.string().email(),
  status: z.literal("otp_required"),
});

export const googleCompletion = z.union([sessionProjection, googleLinkChallenge]);

export const signedOutAnswer = z.object({ signed_out: z.literal(true) });

/** The Cookie transport keeps the claim in an HttpOnly Cookie; the body says only how long it can be redeemed. */
export const guestHandoff = z.object({
  claim: z.never().optional(),
  expires_at: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
});

export const guestImportAnswer = z.object({ import_id: z.string().min(1).max(256) });

export const guestImportMarker = z.strictObject({
  expiresAtEpochSeconds: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
});

export const unauthorized = z.object({ error: z.literal("unauthorized") });
export const sessionChanged = z.object({ error: z.literal("session_changed") });
const errorCode = z.object({ error: z.string() });

const protocolError = z
  .object({
    contract_version: z.literal(1).optional(),
    error: z.enum([
      "invalid_session_precondition",
      "session_lifecycle_version_required",
      "unsupported_session_lifecycle_version",
    ]),
  })
  .or(z.object({ error: z.literal("invalid_session_precondition") }));

export function parsed<S extends z.ZodType>(
  response: AuthResponse,
  schema: S
): z.output<S> | undefined {
  const out = schema.safeParse(response.body);
  return out.success ? out.data : undefined;
}

export const isProtocolError = (response: AuthResponse) =>
  response.status === 400 ||
  response.status === 428 ||
  parsed(response, protocolError) !== undefined;

export const isGuestPowRejection = (response: AuthResponse) =>
  response.status === 400 && parsed(response, errorCode)?.error === "guest_pow_invalid";

export function guestStartRefusal(
  response: AuthResponse
): "provider_unavailable" | "rate_limited" | "unknown" | "unsupported" {
  if (
    response.status === 404 &&
    parsed(response, errorCode)?.error === "guest_mode_disabled"
  )
    return "unsupported";
  if (response.status === 429) return "rate_limited";
  if (response.status >= 500) return "provider_unavailable";
  return "unknown";
}

export function authStartRefusal(
  response: AuthResponse
): "provider_unavailable" | "rate_limited" | "unknown" {
  if (response.status === 429) return "rate_limited";
  if (response.status >= 500) return "provider_unavailable";
  return "unknown";
}

/** What a sign-in says of the client: the web, on the platform its user agent names. */
export function clientMetadata(userAgent: string) {
  const ua = userAgent.toLowerCase();
  const platform = ua.includes("android")
    ? "android"
    : ua.includes("iphone") || ua.includes("ipad") || ua.includes("ipod")
      ? "ios"
      : ua.includes("windows")
        ? "windows"
        : ua.includes("mac os") || ua.includes("macintosh")
          ? "macos"
          : ua.includes("linux")
            ? "linux"
            : "unknown";
  return { client_kind: "web", client_platform: platform } as const;
}

/** Nonces hashed per batch. */
const POW_BATCH = 256;

/**
 * A nonce for the guest challenge: `SHA-256(challenge + ":" + nonce)` with `difficulty` leading zero bits, nonces
 * tried in order (as @comma/session-contract's solver), at most `guestPowMaxAttempts`. Interrupted, it stops. Each
 * batch waits for the host's digests (the browser's are a promise, so the worker answers its pages between batches):
 * how far it got is fixed by those answers, not by turns of the event loop.
 */
export function solveGuestPow(
  challenge: string,
  difficulty: number,
  sha256: (inputs: readonly string[]) => Effect.Effect<Uint8Array[], HostError>
): Effect.Effect<GuestPowSolution | null, HostError> {
  return Effect.gen(function* () {
    const prefix = `${challenge}:`;
    for (let start = 0; start < guestPowMaxAttempts; start += POW_BATCH) {
      const count = Math.min(POW_BATCH, guestPowMaxAttempts - start);
      const nonces = Array.from({ length: count }, (_, i) => String(start + i));
      const digests = yield* sha256(nonces.map((nonce) => prefix + nonce));
      const found = nonces.findIndex((_, i) => {
        const digest = digests[i];
        return digest !== undefined && hasLeadingZeroBits(digest, difficulty);
      });
      if (found >= 0) return { challenge, nonce: nonces[found]! };
    }
    return null;
  });
}
