/*
 * XEd25519 signing over libsodium.
 *
 * XEd25519 follows the deployed variant of CRS-03 section 5: the public
 * XEdDSA specification (https://signal.org/docs/specifications/xeddsa/,
 * public domain) with the Edwards sign bit carried in the signature instead
 * of a negated private scalar. "Spec section" below refers to that document.
 * Scalars are 32-byte little-endian integers; points are the 255-bit
 * little-endian y-coordinate followed by the sign bit of x (RFC 8032
 * encoding).
 */
#include "signal_curve.h"

#include <sodium.h>
#include <string.h>

/* The group order q (spec section 5), little-endian. */
static const uint8_t GROUP_ORDER[SC_SCALAR_BYTES] = {
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7,
    0xa2, 0xde, 0xf9, 0xde, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10};

int sc_scalar_is_canonical(const uint8_t s[SC_SCALAR_BYTES]) {
  /* s < q exactly when s - q borrows out of the top byte. */
  unsigned int borrow = 0;
  for (size_t i = 0; i < SC_SCALAR_BYTES; i++) {
    borrow = (((unsigned int)s[i] - (unsigned int)GROUP_ORDER[i] - borrow) >> 8) & 1u;
  }
  return (int)borrow;
}

/* X25519 scalar clamping (RFC 7748 section 5). Idempotent. */
static void clamp(uint8_t k[SC_SCALAR_BYTES]) {
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
}

/* The hash_i domain-separation prefix (spec section 2.5): the b-bit
 * little-endian encoding of 2^b - 1 - i, with b = 256. */
static void hash_prefix(uint8_t prefix[32], uint8_t i) {
  memset(prefix, 0xff, 32);
  prefix[0] = (uint8_t)(0xff - i);
}

/* SHA-512 over several parts; hash_to_scalar reduces it modulo q. */
typedef struct {
  const uint8_t *data;
  size_t len;
} part_t;

static void hash_parts(uint8_t digest[64], const part_t *parts, size_t count) {
  crypto_hash_sha512_state state;
  crypto_hash_sha512_init(&state);
  for (size_t i = 0; i < count; i++) {
    if (parts[i].len > 0) {
      crypto_hash_sha512_update(&state, parts[i].data, parts[i].len);
    }
  }
  crypto_hash_sha512_final(&state, digest);
  sodium_memzero(&state, sizeof state);
}

static void hash_to_scalar(uint8_t out[SC_SCALAR_BYTES], const part_t *parts, size_t count) {
  uint8_t digest[64];
  hash_parts(digest, parts, count);
  crypto_core_ed25519_scalar_reduce(out, digest);
  sodium_memzero(digest, sizeof digest);
}

int sc_xeddsa_sign(uint8_t signature[SC_XEDDSA_SIGNATURE_BYTES],
                   const uint8_t k[SC_SCALAR_BYTES], const uint8_t *message,
                   size_t message_len, const uint8_t random[SC_RANDOM_BYTES]) {
  uint8_t clamped[SC_SCALAR_BYTES];
  uint8_t wide[64] = {0};
  uint8_t A[SC_POINT_BYTES];
  uint8_t a[SC_SCALAR_BYTES];
  uint8_t prefix[32];
  uint8_t r[SC_SCALAR_BYTES];
  uint8_t R[SC_POINT_BYTES];
  uint8_t h[SC_SCALAR_BYTES];
  uint8_t ha[SC_SCALAR_BYTES];
  uint8_t s[SC_SCALAR_BYTES];
  int ret = -1;

  memcpy(clamped, k, sizeof clamped);
  clamp(clamped);

  /* A = kB, used as computed: the deployed scheme does not negate k when the
   * sign bit b of A is 1 (CRS-03 section 5.2). A clamped scalar is a nonzero
   * multiple of 8 below 2^255 and 8q > 2^255, so A is never the identity and
   * this call does not fail. */
  if (crypto_scalarmult_ed25519_base_noclamp(A, clamped) != 0) {
    goto done;
  }
  const uint8_t sign = (uint8_t)(A[31] >> 7);

  /* a = k (mod q) */
  memcpy(wide, clamped, sizeof clamped);
  crypto_core_ed25519_scalar_reduce(a, wide);

  /* r = SHA512(0xFE || 0xFF * 31 || k || M || Z) (mod q), k clamped. */
  hash_prefix(prefix, 1);
  const part_t nonce_parts[] = {{prefix, sizeof prefix},
                                {clamped, sizeof clamped},
                                {message, message_len},
                                {random, SC_RANDOM_BYTES}};
  hash_to_scalar(r, nonce_parts, 4);

  /* R = rB; r = 0 has negligible probability and is refused. */
  if (crypto_scalarmult_ed25519_base_noclamp(R, r) != 0) {
    goto done;
  }

  /* h = SHA512(R || A || M) (mod q) */
  const part_t challenge_parts[] = {{R, sizeof R}, {A, sizeof A}, {message, message_len}};
  hash_to_scalar(h, challenge_parts, 3);

  /* s = ha + r (mod q). s < q < 2^253, so bit 255 is free for b. */
  crypto_core_ed25519_scalar_mul(ha, h, a);
  crypto_core_ed25519_scalar_add(s, r, ha);

  memcpy(signature, R, SC_POINT_BYTES);
  memcpy(signature + SC_POINT_BYTES, s, SC_SCALAR_BYTES);
  signature[63] |= (uint8_t)(sign << 7);
  ret = 0;

done:
  sodium_memzero(clamped, sizeof clamped);
  sodium_memzero(wide, sizeof wide);
  sodium_memzero(a, sizeof a);
  sodium_memzero(r, sizeof r);
  sodium_memzero(ha, sizeof ha);
  sodium_memzero(s, sizeof s);
  return ret;
}
