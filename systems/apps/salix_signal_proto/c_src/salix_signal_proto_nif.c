/*
 * NIF boundary for salix_signal_proto.
 *
 * Every input is a binary of an exact size, except messages, which are any
 * binary. A wrong type or size raises badarg before any cryptographic work.
 * Ristretto255 points are decoded before use, and scalars other than the
 * reduction input must be canonical (below the group order).
 *
 * Results are computed in stack buffers, copied into a new binary, and then
 * wiped, because a result can be secret (a scalar, or a point times a secret
 * scalar). A failed binary allocation raises enomem.
 *
 * The functions here are the only native code in the Signal protocol core.
 * Everything that handles only public data is in Elixir.
 */
#include <erl_nif.h>
#include <sodium.h>
#include <string.h>

#include "signal_curve.h"

static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_enomem;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  if (sodium_init() < 0) {
    return 1;
  }
  atom_error = enif_make_atom(env, "error");
  atom_enomem = enif_make_atom(env, "enomem");
  atom_true = enif_make_atom(env, "true");
  atom_false = enif_make_atom(env, "false");
  return 0;
}

static int fixed_binary(ErlNifEnv *env, ERL_NIF_TERM term, size_t size, ErlNifBinary *bin) {
  return enif_inspect_binary(env, term, bin) && bin->size == size;
}

/* Returns a new binary with the size bytes at data, and wipes data. */
static ERL_NIF_TERM take_binary(ErlNifEnv *env, uint8_t *data, size_t size) {
  ERL_NIF_TERM term;
  unsigned char *out = enif_make_new_binary(env, size, &term);
  if (out == NULL) {
    sodium_memzero(data, size);
    return enif_raise_exception(env, atom_enomem);
  }
  memcpy(out, data, size);
  sodium_memzero(data, size);
  return term;
}

/* Wipes a result buffer and returns the error atom. */
static ERL_NIF_TERM wipe_error(uint8_t *data, size_t size) {
  sodium_memzero(data, size);
  return atom_error;
}

static int valid_ristretto_point(const ErlNifBinary *bin) {
  return crypto_core_ristretto255_is_valid_point(bin->data) == 1;
}

static int canonical_scalar(const ErlNifBinary *bin) {
  return sc_scalar_is_canonical(bin->data);
}

/* ---- XEdDSA signing ----------------------------------------------------- */

static ERL_NIF_TERM xeddsa_sign(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary k, message, random;
  uint8_t signature[SC_XEDDSA_SIGNATURE_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], SC_SCALAR_BYTES, &k) ||
      !enif_inspect_binary(env, argv[1], &message) ||
      !fixed_binary(env, argv[2], SC_RANDOM_BYTES, &random)) {
    return enif_make_badarg(env);
  }
  if (sc_xeddsa_sign(signature, k.data, message.data, message.size, random.data) != 0) {
    return wipe_error(signature, sizeof signature);
  }
  return take_binary(env, signature, sizeof signature);
}

/* ---- Ristretto255 group (RFC 9496) ------------------------------------- */

static ERL_NIF_TERM ristretto255_is_valid_point(ErlNifEnv *env, int argc,
                                                const ERL_NIF_TERM argv[]) {
  ErlNifBinary p;
  (void)argc;

  if (!enif_inspect_binary(env, argv[0], &p)) {
    return enif_make_badarg(env);
  }
  if (p.size != crypto_core_ristretto255_BYTES) {
    return atom_false;
  }
  return valid_ristretto_point(&p) ? atom_true : atom_false;
}

static ERL_NIF_TERM ristretto255_from_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bytes;
  uint8_t point[crypto_core_ristretto255_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_HASHBYTES, &bytes)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_from_hash(point, bytes.data);
  return take_binary(env, point, sizeof point);
}

static ERL_NIF_TERM ristretto255_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary p, q;
  uint8_t out[crypto_core_ristretto255_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_BYTES, &p) ||
      !fixed_binary(env, argv[1], crypto_core_ristretto255_BYTES, &q) ||
      !valid_ristretto_point(&p) || !valid_ristretto_point(&q)) {
    return enif_make_badarg(env);
  }
  if (crypto_core_ristretto255_add(out, p.data, q.data) != 0) {
    return wipe_error(out, sizeof out);
  }
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM ristretto255_sub(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary p, q;
  uint8_t out[crypto_core_ristretto255_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_BYTES, &p) ||
      !fixed_binary(env, argv[1], crypto_core_ristretto255_BYTES, &q) ||
      !valid_ristretto_point(&p) || !valid_ristretto_point(&q)) {
    return enif_make_badarg(env);
  }
  if (crypto_core_ristretto255_sub(out, p.data, q.data) != 0) {
    return wipe_error(out, sizeof out);
  }
  return take_binary(env, out, sizeof out);
}

/* libsodium reports an identity result as failure. For a valid point and a
 * canonical scalar the identity is a correct group result, so it is returned
 * as the all-zero identity encoding. */
static ERL_NIF_TERM ristretto255_scalarmult(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary n, p;
  uint8_t out[crypto_scalarmult_ristretto255_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_scalarmult_ristretto255_SCALARBYTES, &n) ||
      !fixed_binary(env, argv[1], crypto_scalarmult_ristretto255_BYTES, &p) ||
      !canonical_scalar(&n) || !valid_ristretto_point(&p)) {
    return enif_make_badarg(env);
  }
  if (crypto_scalarmult_ristretto255(out, n.data, p.data) != 0) {
    memset(out, 0, sizeof out);
  }
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM ristretto255_scalarmult_base(ErlNifEnv *env, int argc,
                                                 const ERL_NIF_TERM argv[]) {
  ErlNifBinary n;
  uint8_t out[crypto_scalarmult_ristretto255_BYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_scalarmult_ristretto255_SCALARBYTES, &n) ||
      !canonical_scalar(&n)) {
    return enif_make_badarg(env);
  }
  if (crypto_scalarmult_ristretto255_base(out, n.data) != 0) {
    memset(out, 0, sizeof out);
  }
  return take_binary(env, out, sizeof out);
}

/* ---- Scalars modulo the group order ----------------------------------- */

static ERL_NIF_TERM scalar_is_canonical(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary s;
  (void)argc;

  if (!enif_inspect_binary(env, argv[0], &s)) {
    return enif_make_badarg(env);
  }
  if (s.size != crypto_core_ristretto255_SCALARBYTES) {
    return atom_false;
  }
  return canonical_scalar(&s) ? atom_true : atom_false;
}

static ERL_NIF_TERM scalar_reduce(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary wide;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_NONREDUCEDSCALARBYTES, &wide)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_scalar_reduce(out, wide.data);
  return take_binary(env, out, sizeof out);
}

static int two_scalars(ErlNifEnv *env, const ERL_NIF_TERM argv[], ErlNifBinary *x,
                       ErlNifBinary *y) {
  return fixed_binary(env, argv[0], crypto_core_ristretto255_SCALARBYTES, x) &&
         fixed_binary(env, argv[1], crypto_core_ristretto255_SCALARBYTES, y) &&
         canonical_scalar(x) && canonical_scalar(y);
}

static ERL_NIF_TERM scalar_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary x, y;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!two_scalars(env, argv, &x, &y)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_scalar_add(out, x.data, y.data);
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM scalar_sub(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary x, y;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!two_scalars(env, argv, &x, &y)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_scalar_sub(out, x.data, y.data);
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM scalar_mul(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary x, y;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!two_scalars(env, argv, &x, &y)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_scalar_mul(out, x.data, y.data);
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM scalar_negate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary x;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_SCALARBYTES, &x) ||
      !canonical_scalar(&x)) {
    return enif_make_badarg(env);
  }
  crypto_core_ristretto255_scalar_negate(out, x.data);
  return take_binary(env, out, sizeof out);
}

static ERL_NIF_TERM scalar_invert(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary x;
  uint8_t out[crypto_core_ristretto255_SCALARBYTES];
  (void)argc;

  if (!fixed_binary(env, argv[0], crypto_core_ristretto255_SCALARBYTES, &x) ||
      !canonical_scalar(&x)) {
    return enif_make_badarg(env);
  }
  if (crypto_core_ristretto255_scalar_invert(out, x.data) != 0) {
    return wipe_error(out, sizeof out);
  }
  return take_binary(env, out, sizeof out);
}

static ErlNifFunc nif_funcs[] = {
    {"xeddsa_sign", 3, xeddsa_sign, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ristretto255_is_valid_point", 1, ristretto255_is_valid_point, 0},
    {"ristretto255_from_hash", 1, ristretto255_from_hash, 0},
    {"ristretto255_add", 2, ristretto255_add, 0},
    {"ristretto255_sub", 2, ristretto255_sub, 0},
    {"ristretto255_scalarmult", 2, ristretto255_scalarmult, 0},
    {"ristretto255_scalarmult_base", 1, ristretto255_scalarmult_base, 0},
    {"scalar_is_canonical", 1, scalar_is_canonical, 0},
    {"scalar_reduce", 1, scalar_reduce, 0},
    {"scalar_add", 2, scalar_add, 0},
    {"scalar_sub", 2, scalar_sub, 0},
    {"scalar_mul", 2, scalar_mul, 0},
    {"scalar_negate", 1, scalar_negate, 0},
    {"scalar_invert", 1, scalar_invert, 0},
};

ERL_NIF_INIT(Elixir.SalixSignalProto.Crypto.Native, nif_funcs, load, NULL, NULL, NULL)
