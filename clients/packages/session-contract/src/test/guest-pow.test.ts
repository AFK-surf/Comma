import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  GuestPowAbortedError,
  GuestPowExhaustedError,
  hasLeadingZeroBits,
  solveGuestPow,
  type GuestPowDigestBatch,
} from "../index";

const challenge = "gpow1.eyJpIjoidGVzdCJ9.mac";

function sha256(input: string) {
  return createHash("sha256").update(input, "utf8").digest();
}

const nodeDigestBatch: GuestPowDigestBatch = async (inputs) => inputs.map(sha256);

function leadingZeroBits(digest: Uint8Array) {
  let bits = 0;
  for (const byte of digest) {
    if (byte === 0) {
      bits += 8;
      continue;
    }
    return bits + Math.clz32(byte) - 24;
  }
  return bits;
}

describe("hasLeadingZeroBits", () => {
  it("counts whole zero bytes and the high bits of a partial byte", () => {
    // 0x00 0x1f: 11 leading zero bits.
    const digest = Uint8Array.from([0x00, 0x1f, 0xff]);
    expect(hasLeadingZeroBits(digest, 0)).toBe(true);
    expect(hasLeadingZeroBits(digest, 8)).toBe(true);
    expect(hasLeadingZeroBits(digest, 11)).toBe(true);
    expect(hasLeadingZeroBits(digest, 12)).toBe(false);
    expect(hasLeadingZeroBits(Uint8Array.from([0x80]), 1)).toBe(false);
    expect(hasLeadingZeroBits(Uint8Array.from([0x7f]), 1)).toBe(true);
    expect(hasLeadingZeroBits(Uint8Array.from([0x00]), 9)).toBe(false);
  });
});

describe("solveGuestPow", () => {
  it("finds a nonce whose SHA-256 has the required leading zero bits", async () => {
    let hashed = 0;
    const solution = await solveGuestPow({
      batchSize: 64,
      challenge,
      difficulty: 10,
      digestBatch: async (inputs) => {
        hashed += inputs.length;
        return nodeDigestBatch(inputs);
      },
    });

    expect(solution.challenge).toBe(challenge);
    expect(solution.nonce).toMatch(/^[0-9]{1,20}$/);
    expect(
      leadingZeroBits(sha256(`${challenge}:${solution.nonce}`))
    ).toBeGreaterThanOrEqual(10);
    // Nonces are tried in order, so no smaller nonce solves the challenge.
    for (let nonce = 0; nonce < Number(solution.nonce); nonce += 1) {
      expect(leadingZeroBits(sha256(`${challenge}:${nonce}`))).toBeLessThan(10);
    }
    expect(hashed).toBeLessThanOrEqual(Number(solution.nonce) + 64);
  });

  it("solves the default difficulty within a bounded number of hashes", async () => {
    // Deterministic work count at 14 bits (expected 2^14), above the default 12.
    const solution = await solveGuestPow({
      batchSize: 4_096,
      challenge,
      difficulty: 14,
      digestBatch: nodeDigestBatch,
    });
    expect(
      leadingZeroBits(sha256(`${challenge}:${solution.nonce}`))
    ).toBeGreaterThanOrEqual(14);
    expect(Number(solution.nonce)).toBeLessThan(2 ** 18);
  });

  it("stops at the attempt bound", async () => {
    let hashed = 0;
    await expect(
      solveGuestPow({
        batchSize: 8,
        challenge,
        difficulty: 256,
        digestBatch: async (inputs) => {
          hashed += inputs.length;
          return nodeDigestBatch(inputs);
        },
        maxAttempts: 20,
      })
    ).rejects.toBeInstanceOf(GuestPowExhaustedError);
    expect(hashed).toBe(20);
  });

  it("stops when aborted", async () => {
    const signal = { aborted: false };
    const solving = solveGuestPow({
      batchSize: 8,
      challenge,
      difficulty: 256,
      digestBatch: async (inputs) => {
        signal.aborted = true;
        return nodeDigestBatch(inputs);
      },
      signal,
    });
    await expect(solving).rejects.toBeInstanceOf(GuestPowAbortedError);
  });
});
