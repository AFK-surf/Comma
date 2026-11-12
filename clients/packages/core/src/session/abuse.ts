import { lazySchema } from "@comma/chat-contract";
import { z } from "zod";

/** The existing one-time credential is the action's only challenge authority. */
export const abuseChallenge = lazySchema(() =>
  z.object({
    id: z
      .string()
      .min(1)
      .max(200)
      .regex(/^[A-Za-z0-9_-]+$/),
    secret: z
      .string()
      .min(1)
      .max(200)
      .regex(/^[A-Za-z0-9_-]+$/),
    expires_at: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
    method: z.enum(["native", "captcha"]),
    enforce: z.boolean(),
    action: z.enum(["email_login", "registration"]),
    email: z.string().email().max(320),
    pow_difficulty: z.number().int().min(1).max(24).optional(),
    captcha_url: z.string().url().max(2048).optional(),
    apple_environment: z.enum(["development", "production"]).optional(),
    google_cloud_project_number: z
      .string()
      .regex(/^[0-9]{1,20}$/)
      .optional(),
  })
);

export const abuseRequired = lazySchema(() =>
  z.object({
    error: z.enum(["captcha_required", "native_proof_required"]),
    challenge: abuseChallenge,
    registration_continuation: z.string().min(1).max(512).optional(),
  })
);

export type AbuseChallenge = z.output<typeof abuseChallenge>;
export type NativeAbuseProof =
  | {
      provider: "apple";
      apple: { key_id: string; attestation?: string; assertion?: string };
    }
  | { provider: "play"; play_token: string };
export type AbuseEvidence = {
  challenge_id: string;
  challenge_secret: string;
  pow_nonce?: string;
} & (
  | NativeAbuseProof
  | { provider: "turnstile"; captcha_token: string }
  | { provider: "unavailable" }
);

export class AbuseError extends Error {
  readonly code: "cancelled" | "protocol_mismatch" | "provider_unavailable";
  constructor(code: "cancelled" | "protocol_mismatch" | "provider_unavailable") {
    super(code);
    this.code = code;
  }
}

/** UTF-8 before hashing. Neither credential alphabet contains the delimiter. */
export const abuseProofInput = (challenge: Pick<AbuseChallenge, "id" | "secret">) =>
  `comma-abuse:${challenge.id}:${challenge.secret}`;

/** A page gets only its public challenge ID and action, never an attempt credential. */
export function captchaPage(challenge: AbuseChallenge, origin: string): string | null {
  if (!challenge.captcha_url) return null;
  try {
    const url = new URL(challenge.captcha_url);
    if (
      url.origin !== new URL(origin).origin ||
      url.username !== "" ||
      url.password !== "" ||
      url.pathname !== "/v1/comma/auth/captcha" ||
      url.searchParams.get("challenge_id") !== challenge.id ||
      url.searchParams.get("action") !== challenge.action ||
      Array.from(url.searchParams.keys()).some(
        (key) => key !== "challenge_id" && key !== "action"
      ) ||
      url.hash !== ""
    )
      return null;
    return url.href;
  } catch {
    return null;
  }
}
