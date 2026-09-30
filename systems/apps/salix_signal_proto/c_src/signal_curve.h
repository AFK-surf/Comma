/*
 * Secret-dependent Curve25519 operations for salix_signal_proto.
 *
 * Every function takes fixed-size inputs that the Elixir caller has already
 * checked. All secret-dependent work goes through libsodium's constant-time
 * group and scalar operations. Public-data operations (verification) are in
 * Elixir, not here.
 *
 * Specifications: CRS-03 section 5 (deployed XEd25519) and "The XEdDSA and
 * VXEdDSA Signature Schemes", revision 1,
 * https://signal.org/docs/specifications/xeddsa/ (public domain). VXEdDSA is
 * not implemented: no deployed step uses it (CRS-03 section 5.4).
 */
#ifndef SALIX_SIGNAL_CURVE_H
#define SALIX_SIGNAL_CURVE_H

#include <stddef.h>
#include <stdint.h>

#define SC_SCALAR_BYTES 32
#define SC_POINT_BYTES 32
#define SC_RANDOM_BYTES 64
#define SC_XEDDSA_SIGNATURE_BYTES 64

/* Returns 1 when s (little-endian) is less than the group order q, else 0.
 * Runs in constant time. */
int sc_scalar_is_canonical(const uint8_t s[SC_SCALAR_BYTES]);

/* XEd25519 signing as deployed (CRS-03 section 5.2). k is an X25519 private
 * key; it is clamped as X25519 clamps it. The signature is R || s with the
 * sign bit of A = kB in bit 7 of byte 63. Returns 0 on success, -1 on
 * failure. */
int sc_xeddsa_sign(uint8_t signature[SC_XEDDSA_SIGNATURE_BYTES],
                   const uint8_t k[SC_SCALAR_BYTES], const uint8_t *message,
                   size_t message_len, const uint8_t random[SC_RANDOM_BYTES]);

#endif
