/*
 * Sanitizer driver for signal_curve.c (make sanitize-test).
 *
 * Built with AddressSanitizer and UndefinedBehaviorSanitizer and run in CI.
 * It exercises the signing core with random and edge-case inputs, and checks
 * each XEd25519 signature with libsodium's independent Ed25519 verifier:
 * with bit 7 of byte 63 cleared, a deployed XEd25519 signature is a standard
 * Ed25519 signature under A = kB for the clamped k (CRS-03 section 5.3).
 */
#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "signal_curve.h"

#define ITERATIONS 2000
#define MAX_MESSAGE 512

static int failures = 0;

static void fail(const char *what, int iteration) {
  fprintf(stderr, "FAIL: %s (iteration %d)\n", what, iteration);
  failures++;
}

/* A = kB for the clamped k, with its sign bit (CRS-03 section 5.2). */
static void edwards_public_key(uint8_t A[32], const uint8_t k[32]) {
  uint8_t clamped[32];
  memcpy(clamped, k, 32);
  clamped[0] &= 248;
  clamped[31] &= 127;
  clamped[31] |= 64;
  if (crypto_scalarmult_ed25519_base_noclamp(A, clamped) != 0) {
    memset(A, 0, 32);
  }
}

static void check_key(const uint8_t k[32], const uint8_t *message, size_t len, int iteration) {
  uint8_t random[SC_RANDOM_BYTES];
  uint8_t signature[SC_XEDDSA_SIGNATURE_BYTES];
  uint8_t again[SC_XEDDSA_SIGNATURE_BYTES];
  uint8_t A[32];

  randombytes_buf(random, sizeof random);
  edwards_public_key(A, k);

  if (sc_xeddsa_sign(signature, k, message, len, random) != 0) {
    fail("xeddsa_sign returned an error", iteration);
    return;
  }
  /* The signature carries the sign bit of A in bit 7 of byte 63. With that
   * bit cleared it is a standard Ed25519 signature under A. */
  if ((signature[63] >> 7) != (A[31] >> 7)) {
    fail("signature does not carry the sign bit of A", iteration);
  }
  uint8_t standard[SC_XEDDSA_SIGNATURE_BYTES];
  memcpy(standard, signature, sizeof standard);
  standard[63] &= 0x7f;
  if (crypto_sign_ed25519_verify_detached(standard, message, len, A) != 0) {
    fail("Ed25519 verifier rejected an XEd25519 signature", iteration);
  }
  if (sc_xeddsa_sign(again, k, message, len, random) != 0 ||
      memcmp(signature, again, sizeof signature) != 0) {
    fail("xeddsa_sign is not a function of its inputs", iteration);
  }
  if (len > 0) {
    uint8_t *tampered = malloc(len);
    memcpy(tampered, message, len);
    tampered[0] ^= 1;
    if (crypto_sign_ed25519_verify_detached(standard, tampered, len, A) == 0) {
      fail("signature verified for a different message", iteration);
    }
    free(tampered);
  }
}

int main(void) {
  static const uint8_t order[32] = {0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
                                    0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
                                    0,    0,    0,    0,    0,    0,    0,    0,
                                    0,    0,    0,    0,    0,    0,    0,    0x10};
  uint8_t k[32];
  uint8_t scalar[32];
  uint8_t message[MAX_MESSAGE];

  if (sodium_init() < 0) {
    fprintf(stderr, "sodium_init failed\n");
    return 2;
  }

  /* Canonical scalar boundary. */
  memcpy(scalar, order, 32);
  if (sc_scalar_is_canonical(scalar)) fail("q accepted as canonical", 0);
  scalar[0]--;
  if (!sc_scalar_is_canonical(scalar)) fail("q - 1 rejected", 0);
  memset(scalar, 0, 32);
  if (!sc_scalar_is_canonical(scalar)) fail("0 rejected", 0);
  memset(scalar, 0xff, 32);
  if (sc_scalar_is_canonical(scalar)) fail("2^256 - 1 accepted", 0);

  /* Edge-case private keys, including ones clamping changes. */
  memset(k, 0, 32);
  check_key(k, (const uint8_t *)"", 0, -1);
  memset(k, 0xff, 32);
  check_key(k, (const uint8_t *)"m", 1, -2);

  for (int i = 0; i < ITERATIONS; i++) {
    size_t len = randombytes_uniform(MAX_MESSAGE + 1);
    randombytes_buf(k, sizeof k);
    randombytes_buf(message, len);
    check_key(k, message, len, i);
  }

  if (failures != 0) {
    fprintf(stderr, "%d failures\n", failures);
    return 1;
  }
  printf("signal_curve: %d iterations passed\n", ITERATIONS);
  return 0;
}
