import { z } from "zod";

/**
 * Light SHA-256 proof of work for guest creation.
 *
 * `GET /v1/comma/auth/guest` returns a signed challenge. The client finds a
 * decimal nonce so that `SHA-256(challenge + ":" + nonce)` starts with at
 * least `difficulty` zero bits, then sends both in the create request. One
 * solved challenge creates at most one guest, so each attempt uses a fresh
 * challenge. Guest mode is web-only; the web host injects a WebCrypto digest.
 */

/**
 * Upper bound on nonces tried for one challenge. It keeps every nonce within
 * the server's 1..20 digit limit and bounds the work for a hostile difficulty.
 */
export const guestPowMaxAttempts = 2 ** 26;

export const guestPowChallengeSchema = z.object({
  challenge: z.string().min(1).max(2_048),
  difficulty: z.number().int().min(1).max(64),
  expires_at: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
});

/** Remote `GET /v1/comma/auth/guest` body. `pow` is present when enabled. */
export const guestAvailabilityRemoteSchema = z.object({
  enabled: z.boolean(),
  pow: guestPowChallengeSchema.optional(),
});

export type GuestPowChallenge = z.output<typeof guestPowChallengeSchema>;

export interface GuestPowSolution {
  challenge: string;
  nonce: string;
}

/**
 * Hashes each input (`challenge:nonce`, UTF-8) with SHA-256. The result order
 * must match the input order.
 */
export type GuestPowDigestBatch = (
  inputs: readonly string[]
) => Promise<readonly Uint8Array[]>;

export class GuestPowExhaustedError extends Error {
  constructor() {
    super("No proof-of-work nonce found within the attempt bound.");
    this.name = "GuestPowExhaustedError";
  }
}

export class GuestPowAbortedError extends Error {
  constructor() {
    super("Proof-of-work solving was aborted.");
    this.name = "GuestPowAbortedError";
  }
}

/** Whether `digest` starts with at least `bits` zero bits, MSB of byte 0 first. */
export function hasLeadingZeroBits(digest: Uint8Array, bits: number): boolean {
  if (!Number.isInteger(bits) || bits < 0 || bits > digest.length * 8) return false;
  const fullBytes = Math.floor(bits / 8);
  for (let index = 0; index < fullBytes; index += 1) {
    if (digest[index] !== 0) return false;
  }
  const remainder = bits % 8;
  if (remainder === 0) return true;
  const mask = (0xff << (8 - remainder)) & 0xff;
  return ((digest[fullBytes] ?? 0xff) & mask) === 0;
}

export async function solveGuestPow(options: {
  batchSize: number;
  challenge: string;
  difficulty: number;
  digestBatch: GuestPowDigestBatch;
  maxAttempts?: number | undefined;
  signal?: { readonly aborted: boolean } | undefined;
}): Promise<GuestPowSolution> {
  const { challenge, difficulty, digestBatch } = options;
  const batchSize = Math.max(1, Math.trunc(options.batchSize));
  const maxAttempts = Math.min(
    options.maxAttempts ?? guestPowMaxAttempts,
    guestPowMaxAttempts
  );
  const prefix = `${challenge}:`;

  for (let start = 0; start < maxAttempts; start += batchSize) {
    if (options.signal?.aborted) throw new GuestPowAbortedError();
    const count = Math.min(batchSize, maxAttempts - start);
    const nonces: string[] = [];
    for (let offset = 0; offset < count; offset += 1) {
      nonces.push(String(start + offset));
    }
    const digests = await digestBatch(nonces.map((nonce) => prefix + nonce));
    for (let index = 0; index < nonces.length; index += 1) {
      const digest = digests[index];
      const nonce = nonces[index];
      if (digest && nonce && hasLeadingZeroBits(digest, difficulty)) {
        return { challenge, nonce };
      }
    }
  }
  throw new GuestPowExhaustedError();
}
