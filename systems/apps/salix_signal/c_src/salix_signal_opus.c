/*
 * Opus encoder and decoder NIF for Signal call media (CRS-13 section 7).
 *
 * Audio is 16-bit signed little-endian mono PCM at the rate given when the
 * codec is created (8, 12, 16, 24 or 48 kHz). libopus converts between that
 * rate and the 48 kHz RTP clock itself, so no separate resampler is needed.
 *
 * Each codec is a resource with its own mutex, so a call from any process is
 * safe. Every input is checked before libopus sees it: PCM must be a whole
 * number of samples and a valid Opus frame length, packets at most 1500
 * bytes, and decode lengths at most 120 ms.
 */
#include <erl_nif.h>
#include <opus.h>
#include <string.h>

#define MAX_PACKET_BYTES 1500
#define MAX_FRAME_MS 120

typedef struct {
  OpusEncoder *encoder;
  ErlNifMutex *lock;
  int rate;
} encoder_res;

typedef struct {
  OpusDecoder *decoder;
  ErlNifMutex *lock;
  int rate;
} decoder_res;

static ErlNifResourceType *encoder_type;
static ErlNifResourceType *decoder_type;
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_nil;

static void encoder_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  encoder_res *res = obj;
  if (res->encoder) opus_encoder_destroy(res->encoder);
  if (res->lock) enif_mutex_destroy(res->lock);
}

static void decoder_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  decoder_res *res = obj;
  if (res->decoder) opus_decoder_destroy(res->decoder);
  if (res->lock) enif_mutex_destroy(res->lock);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
  encoder_type = enif_open_resource_type(env, NULL, "salix_signal_opus_encoder", encoder_dtor, flags, NULL);
  decoder_type = enif_open_resource_type(env, NULL, "salix_signal_opus_decoder", decoder_dtor, flags, NULL);
  if (!encoder_type || !decoder_type) return 1;
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  atom_nil = enif_make_atom(env, "nil");
  return 0;
}

static int valid_rate(int rate) {
  return rate == 8000 || rate == 12000 || rate == 16000 || rate == 24000 || rate == 48000;
}

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, int code) {
  const char *reason;
  switch (code) {
    case OPUS_BAD_ARG: reason = "bad_arg"; break;
    case OPUS_BUFFER_TOO_SMALL: reason = "buffer_too_small"; break;
    case OPUS_INVALID_PACKET: reason = "invalid_packet"; break;
    case OPUS_ALLOC_FAIL: reason = "alloc_fail"; break;
    default: reason = "internal_error"; break;
  }
  return enif_make_tuple2(env, atom_error, enif_make_atom(env, reason));
}

/* encoder_new(rate, bitrate, complexity, fec, dtx, cbr, loss_percent) */
static ERL_NIF_TERM encoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int rate, bitrate, complexity, fec, dtx, cbr, loss;
  (void)argc;
  if (!enif_get_int(env, argv[0], &rate) || !valid_rate(rate) ||
      !enif_get_int(env, argv[1], &bitrate) || bitrate < 6000 || bitrate > 510000 ||
      !enif_get_int(env, argv[2], &complexity) || complexity < 0 || complexity > 10 ||
      !enif_get_int(env, argv[3], &fec) || !enif_get_int(env, argv[4], &dtx) ||
      !enif_get_int(env, argv[5], &cbr) || !enif_get_int(env, argv[6], &loss) ||
      loss < 0 || loss > 100) {
    return enif_make_badarg(env);
  }

  encoder_res *res = enif_alloc_resource(encoder_type, sizeof(encoder_res));
  memset(res, 0, sizeof(*res));
  res->rate = rate;
  res->lock = enif_mutex_create("salix_signal_opus_encoder");

  int err = OPUS_OK;
  res->encoder = opus_encoder_create(rate, 1, OPUS_APPLICATION_VOIP, &err);
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_BITRATE(bitrate));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_COMPLEXITY(complexity));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_INBAND_FEC(fec ? 1 : 0));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_DTX(dtx ? 1 : 0));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_VBR(cbr ? 0 : 1));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_PACKET_LOSS_PERC(loss));
  if (err == OPUS_OK) err = opus_encoder_ctl(res->encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));

  if (err != OPUS_OK || res->lock == NULL) {
    enif_release_resource(res);
    return error_tuple(env, err == OPUS_OK ? OPUS_ALLOC_FAIL : err);
  }

  ERL_NIF_TERM term = enif_make_resource(env, res);
  enif_release_resource(res);
  return enif_make_tuple2(env, atom_ok, term);
}

/* encode(encoder, pcm) -> {:ok, packet} | {:error, reason} */
static ERL_NIF_TERM encode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  encoder_res *res;
  ErlNifBinary pcm;
  unsigned char out[MAX_PACKET_BYTES];
  (void)argc;

  if (!enif_get_resource(env, argv[0], encoder_type, (void **)&res) ||
      !enif_inspect_binary(env, argv[1], &pcm) || pcm.size % 2 != 0 || pcm.size == 0 ||
      pcm.size / 2 > (size_t)(res->rate / 1000 * MAX_FRAME_MS)) {
    return enif_make_badarg(env);
  }

  int samples = (int)(pcm.size / 2);
  opus_int16 input[48 * MAX_FRAME_MS];
  memcpy(input, pcm.data, pcm.size);

  enif_mutex_lock(res->lock);
  opus_int32 n = opus_encode(res->encoder, input, samples, out, MAX_PACKET_BYTES);
  enif_mutex_unlock(res->lock);

  if (n < 0) return error_tuple(env, n);

  ERL_NIF_TERM packet;
  unsigned char *data = enif_make_new_binary(env, (size_t)n, &packet);
  memcpy(data, out, (size_t)n);
  return enif_make_tuple2(env, atom_ok, packet);
}

/* decoder_new(rate) */
static ERL_NIF_TERM decoder_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int rate;
  (void)argc;
  if (!enif_get_int(env, argv[0], &rate) || !valid_rate(rate)) return enif_make_badarg(env);

  decoder_res *res = enif_alloc_resource(decoder_type, sizeof(decoder_res));
  memset(res, 0, sizeof(*res));
  res->rate = rate;
  res->lock = enif_mutex_create("salix_signal_opus_decoder");

  int err = OPUS_OK;
  res->decoder = opus_decoder_create(rate, 1, &err);
  if (err != OPUS_OK || res->lock == NULL) {
    enif_release_resource(res);
    return error_tuple(env, err == OPUS_OK ? OPUS_ALLOC_FAIL : err);
  }

  ERL_NIF_TERM term = enif_make_resource(env, res);
  enif_release_resource(res);
  return enif_make_tuple2(env, atom_ok, term);
}

/*
 * decode(decoder, packet | nil, samples, fec) -> {:ok, pcm} | {:error, reason}
 *
 * packet nil conceals `samples` of lost audio. With fec = 1, the packet is
 * the one after a loss and its in-band FEC data rebuilds the lost `samples`.
 */
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  decoder_res *res;
  ErlNifBinary packet;
  int samples, fec;
  const unsigned char *data = NULL;
  opus_int32 len = 0;
  (void)argc;

  if (!enif_get_resource(env, argv[0], decoder_type, (void **)&res) ||
      !enif_get_int(env, argv[2], &samples) || samples <= 0 ||
      samples > res->rate / 1000 * MAX_FRAME_MS || !enif_get_int(env, argv[3], &fec)) {
    return enif_make_badarg(env);
  }

  if (!enif_is_identical(argv[1], atom_nil)) {
    if (!enif_inspect_binary(env, argv[1], &packet) || packet.size == 0 ||
        packet.size > MAX_PACKET_BYTES) {
      return enif_make_badarg(env);
    }
    data = packet.data;
    len = (opus_int32)packet.size;
  }

  opus_int16 output[48 * MAX_FRAME_MS];
  enif_mutex_lock(res->lock);
  int n = opus_decode(res->decoder, data, len, output, samples, fec ? 1 : 0);
  enif_mutex_unlock(res->lock);

  if (n < 0) return error_tuple(env, n);

  ERL_NIF_TERM pcm;
  unsigned char *out = enif_make_new_binary(env, (size_t)n * 2, &pcm);
  memcpy(out, output, (size_t)n * 2);
  return enif_make_tuple2(env, atom_ok, pcm);
}

/* packet_samples(packet, rate) -> {:ok, samples} | {:error, reason} */
static ERL_NIF_TERM packet_samples(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary packet;
  int rate;
  (void)argc;
  if (!enif_inspect_binary(env, argv[0], &packet) || packet.size == 0 ||
      packet.size > MAX_PACKET_BYTES || !enif_get_int(env, argv[1], &rate) || !valid_rate(rate)) {
    return enif_make_badarg(env);
  }
  int n = opus_packet_get_nb_samples(packet.data, (opus_int32)packet.size, rate);
  if (n < 0) return error_tuple(env, n);
  return enif_make_tuple2(env, atom_ok, enif_make_int(env, n));
}

static ErlNifFunc funcs[] = {
    {"encoder_new", 7, encoder_new, 0},
    {"encode", 2, encode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decoder_new", 1, decoder_new, 0},
    {"decode", 4, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"packet_samples", 2, packet_samples, 0},
};

ERL_NIF_INIT(Elixir.SalixSignal.CallMedia.Opus.Native, funcs, load, NULL, NULL, NULL)
