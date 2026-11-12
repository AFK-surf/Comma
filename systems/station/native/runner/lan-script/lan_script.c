// SPDX-License-Identifier: Apache-2.0
// The LAN script runtime (lan_script.h): one Micro QuickJS context per run, in the caller's heap, with
// the host functions the prelude (lan_script_prelude.inc) builds the script's API from.
//
// Micro QuickJS moves objects when it collects garbage, and a string a JSValue points to can move with
// any allocation. So every host function copies its string arguments out (arg_copy) before it makes
// another JSValue, and holds no JSValue across an allocation.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lan_script.h"
#include "lan_script_crypto.h"
#include "mquickjs.h"

// Bounds of one host call's own inputs and outputs, whatever the heap.
#define MAX_BYTES_ARG (256 * 1024)
#define MAX_RANDOM 1024
#define MAX_ERROR 2048
// Below this, creating the context itself runs out of memory, which Micro QuickJS does not survive.
#define MIN_HEAP (16 * 1024)

typedef struct {
    char *buf;
    size_t len, cap;
    bool oom;
} sbuf_t;

typedef struct {
    const lan_script_host_t *host;
    const lan_script_limits_t *limits;
    // Why the interrupt handler stopped the script, when it did.
    const char *stopped;
    // The log lines as JSON strings, comma-separated.
    sbuf_t logs;
    bool logs_truncated;
    // What the engine printed of an exception.
    sbuf_t printed;
} run_t;

static bool sb_put(sbuf_t *b, const char *s, size_t n)
{
    if (b->oom) return false;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) cap *= 2;
        char *grown = realloc(b->buf, cap);
        if (!grown) {
            b->oom = true;
            return false;
        }
        b->buf = grown;
        b->cap = cap;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return true;
}

static bool sb_str(sbuf_t *b, const char *s) { return sb_put(b, s, strlen(s)); }

// s as a JSON string. Invalid UTF-8 bytes become U+FFFD.
static bool sb_json(sbuf_t *b, const char *s, size_t n);

// ── base64 and UTF-8 ──

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *b64_encode(const uint8_t *in, size_t n, size_t *out_len)
{
    size_t len = 4 * ((n + 2) / 3);
    char *out = malloc(len + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < n) v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = B64[(v >> 18) & 63];
        out[o++] = B64[(v >> 12) & 63];
        out[o++] = i + 1 < n ? B64[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < n ? B64[v & 63] : '=';
    }
    out[o] = '\0';
    if (out_len) *out_len = o;
    return out;
}

static int b64_value(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// Standard base64 with padding. NULL (and *bad set) when it is not; NULL with *bad clear when out of memory.
static uint8_t *b64_decode(const char *in, size_t n, size_t *out_len, bool *bad)
{
    *bad = false;
    if (n % 4 != 0) {
        *bad = true;
        return NULL;
    }
    uint8_t *out = malloc(n / 4 * 3 + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 4) {
        int v[4];
        for (int k = 0; k < 4; k++) {
            v[k] = in[i + k] == '=' && i + 4 == n && k >= 2 ? -2 : b64_value(in[i + k]);
        }
        if (v[0] < 0 || v[1] < 0 || v[2] == -1 || v[3] == -1 || (v[2] == -2 && v[3] != -2)) {
            free(out);
            *bad = true;
            return NULL;
        }
        uint32_t w = (uint32_t)v[0] << 18 | (uint32_t)v[1] << 12 | (uint32_t)(v[2] < 0 ? 0 : v[2]) << 6 |
                     (uint32_t)(v[3] < 0 ? 0 : v[3]);
        out[o++] = (uint8_t)(w >> 16);
        if (v[2] >= 0) out[o++] = (uint8_t)(w >> 8);
        if (v[3] >= 0) out[o++] = (uint8_t)w;
    }
    *out_len = o;
    return out;
}

// Length of the valid UTF-8 sequence at s (at most n bytes), or 0 when it is not one.
static size_t utf8_seq(const uint8_t *s, size_t n)
{
    uint8_t c = s[0];
    size_t len;
    uint32_t cp;
    if (c < 0x80) return 1;
    if (c >= 0xC2 && c <= 0xDF) len = 2, cp = c & 0x1F;
    else if (c >= 0xE0 && c <= 0xEF) len = 3, cp = c & 0x0F;
    else if (c >= 0xF0 && c <= 0xF4) len = 4, cp = c & 0x07;
    else return 0;
    if (len > n) return 0;
    for (size_t i = 1; i < len; i++) {
        if ((s[i] & 0xC0) != 0x80) return 0;
        cp = cp << 6 | (s[i] & 0x3F);
    }
    if ((len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF))
        return 0;
    return len;
}

// The bytes as UTF-8 text, invalid sequences replaced by U+FFFD.
static char *utf8_clean(const uint8_t *in, size_t n, size_t *out_len)
{
    char *out = malloc(n * 3 + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n;) {
        size_t len = utf8_seq(in + i, n - i);
        if (len) {
            memcpy(out + o, in + i, len);
            o += len;
            i += len;
        } else {
            memcpy(out + o, "\xEF\xBF\xBD", 3);
            o += 3;
            i++;
        }
    }
    out[o] = '\0';
    *out_len = o;
    return out;
}

static bool sb_json(sbuf_t *b, const char *s, size_t n)
{
    size_t clean_len;
    char *clean = utf8_clean((const uint8_t *)s, n, &clean_len);
    if (!clean) {
        b->oom = true;
        return false;
    }
    sb_put(b, "\"", 1);
    for (size_t i = 0; i < clean_len; i++) {
        unsigned char c = (unsigned char)clean[i];
        char esc[8];
        if (c == '"' || c == '\\') {
            esc[0] = '\\';
            esc[1] = (char)c;
            sb_put(b, esc, 2);
        } else if (c < 0x20) {
            snprintf(esc, sizeof(esc), "\\u%04x", c);
            sb_put(b, esc, 6);
        } else {
            sb_put(b, (const char *)&clean[i], 1);
        }
    }
    free(clean);
    return sb_put(b, "\"", 1);
}

// ── host functions ──

static run_t *run_of(JSContext *ctx) { return JS_GetContextOpaque(ctx); }

static JSValue throw_msg(JSContext *ctx, const char *fmt, ...)
{
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    return JS_ThrowError(ctx, JS_CLASS_ERROR, "%s", msg);
}

// Argument i as a malloc'd copy of its string, NUL-terminated. Missing, undefined or null: NULL with
// *present false. Not a string: a TypeError (returns NULL, *thrown set).
static char *arg_copy(JSContext *ctx, int argc, JSValue *argv, int i, const char *name, size_t *len, bool *present,
                      JSValue *thrown)
{
    *present = false;
    *len = 0;
    if (i >= argc || JS_IsUndefined(argv[i]) || JS_IsNull(argv[i])) return NULL;
    if (!JS_IsString(ctx, argv[i])) {
        *thrown = JS_ThrowTypeError(ctx, "%s must be a string", name);
        return NULL;
    }
    JSCStringBuf tmp;
    const char *s = JS_ToCStringLen(ctx, len, argv[i], &tmp);
    if (!s) {
        *thrown = JS_EXCEPTION;
        return NULL;
    }
    char *copy = malloc(*len + 1);
    if (!copy) {
        *thrown = JS_ThrowOutOfMemory(ctx);
        return NULL;
    }
    memcpy(copy, s, *len);
    copy[*len] = '\0';
    *present = true;
    return copy;
}

// Argument i decoded from base64. Required unless optional; *len 0 and NULL when absent.
static uint8_t *arg_bytes(JSContext *ctx, int argc, JSValue *argv, int i, const char *name, bool optional,
                          size_t *len, bool *present, JSValue *thrown)
{
    size_t text_len;
    char *text = arg_copy(ctx, argc, argv, i, name, &text_len, present, thrown);
    *len = 0;
    if (!text) {
        if (!*present && JS_IsUndefined(*thrown) && !optional) *thrown = JS_ThrowTypeError(ctx, "%s is required", name);
        return NULL;
    }
    if (text_len > MAX_BYTES_ARG) {
        free(text);
        *thrown = throw_msg(ctx, "%s is longer than %d bytes of base64", name, MAX_BYTES_ARG);
        return NULL;
    }
    bool bad;
    uint8_t *data = b64_decode(text, text_len, len, &bad);
    free(text);
    if (!data) *thrown = bad ? JS_ThrowTypeError(ctx, "%s must be base64", name) : JS_ThrowOutOfMemory(ctx);
    return data;
}

static JSValue new_b64(JSContext *ctx, const uint8_t *data, size_t n)
{
    size_t len;
    char *text = b64_encode(data, n, &len);
    if (!text) return JS_ThrowOutOfMemory(ctx);
    JSValue v = JS_NewStringLen(ctx, text, len);
    free(text);
    return v;
}

static bool interrupt(JSContext *ctx, void *opaque);

// __lan(method, params_json): one LAN method of the gateway; its result as JSON text.
static JSValue js_lan_call(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    JSValue thrown = JS_UNDEFINED;
    size_t method_len, params_len;
    bool present;
    char *method = arg_copy(ctx, argc, argv, 0, "method", &method_len, &present, &thrown);
    if (!method) return JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "method is required") : thrown;
    char *params = arg_copy(ctx, argc, argv, 1, "params", &params_len, &present, &thrown);
    if (!params) {
        free(method);
        return JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "params is required") : thrown;
    }
    if (interrupt(ctx, run)) {
        free(method);
        free(params);
        return JS_ThrowInternalError(ctx, "interrupted");
    }
    char *out = NULL;
    bool ok = run->host->call(run->host->ctx, method, params, params_len, &out);
    free(method);
    free(params);
    if (!out) return JS_ThrowOutOfMemory(ctx);
    JSValue v = ok ? JS_NewStringLen(ctx, out, strlen(out)) : JS_ThrowError(ctx, JS_CLASS_ERROR, "%s", out);
    free(out);
    return v;
}

static bool aes_key_ok(size_t n) { return n == 16 || n == 24 || n == 32; }

// __aes(mode, encrypt, key, iv, data, aad, tag): mode "ecb", "cbc" or "gcm". GCM encryption answers
// "<data>:<tag>"; the prelude splits it.
static JSValue js_lan_aes(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    JSValue thrown = JS_UNDEFINED, result = JS_UNDEFINED;
    size_t mode_len, key_len = 0, iv_len = 0, data_len = 0, aad_len = 0, tag_len = 0;
    bool present;
    uint8_t *key = NULL, *iv = NULL, *data = NULL, *aad = NULL, *tag = NULL, *out = NULL;
    char *mode = arg_copy(ctx, argc, argv, 0, "mode", &mode_len, &present, &thrown);
    if (!mode) return JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "mode is required") : thrown;
    bool cbc = strcmp(mode, "cbc") == 0, gcm = strcmp(mode, "gcm") == 0;
    if (!cbc && !gcm && strcmp(mode, "ecb") != 0) {
        result = JS_ThrowTypeError(ctx, "mode must be ecb, cbc or gcm");
        goto done;
    }
    bool encrypt = argc > 1 && JS_IsBool(argv[1]) && argv[1] == JS_TRUE;
    if (!(key = arg_bytes(ctx, argc, argv, 2, "key", false, &key_len, &present, &thrown))) goto fail;
    iv = arg_bytes(ctx, argc, argv, 3, "iv", !(cbc || gcm), &iv_len, &present, &thrown);
    if (!JS_IsUndefined(thrown)) goto fail;
    if (!(data = arg_bytes(ctx, argc, argv, 4, "data", false, &data_len, &present, &thrown)) && !JS_IsUndefined(thrown))
        goto fail;
    aad = arg_bytes(ctx, argc, argv, 5, "aad", true, &aad_len, &present, &thrown);
    if (!JS_IsUndefined(thrown)) goto fail;
    tag = arg_bytes(ctx, argc, argv, 6, "tag", !(gcm && !encrypt), &tag_len, &present, &thrown);
    if (!JS_IsUndefined(thrown)) goto fail;
    if (!aes_key_ok(key_len)) {
        result = JS_ThrowRangeError(ctx, "key must be 16, 24 or 32 bytes");
        goto done;
    }
    if (cbc && iv_len != 16) {
        result = JS_ThrowRangeError(ctx, "iv must be 16 bytes for cbc");
        goto done;
    }
    if (!cbc && !gcm && iv_len) {
        result = JS_ThrowTypeError(ctx, "ecb takes no iv");
        goto done;
    }
    if (gcm && iv_len != 12) {
        result = JS_ThrowRangeError(ctx, "iv must be 12 bytes for gcm");
        goto done;
    }
    if (!gcm && data_len % 16) {
        result = JS_ThrowRangeError(ctx, "data must be a multiple of 16 bytes (give padding: \"pkcs7\")");
        goto done;
    }
    if (gcm && !encrypt && tag_len != 16) {
        result = JS_ThrowRangeError(ctx, "tag must be 16 bytes");
        goto done;
    }
    if (!(out = malloc(data_len + 1))) {
        result = JS_ThrowOutOfMemory(ctx);
        goto done;
    }
    if (gcm) {
        uint8_t mac[16];
        if (!encrypt) memcpy(mac, tag, 16);
        if (lan_crypto_aes_gcm(encrypt, key, key_len, iv, iv_len, aad, aad_len, data, data_len, out, mac)) {
            result = throw_msg(ctx, encrypt ? "aes-gcm failed" : "aes-gcm: the tag does not match");
            goto done;
        }
        if (encrypt) {
            size_t a_len, b_len;
            char *a = b64_encode(out, data_len, &a_len), *b = b64_encode(mac, 16, &b_len);
            char *joined = a && b ? malloc(a_len + b_len + 2) : NULL;
            if (joined) {
                memcpy(joined, a, a_len);
                joined[a_len] = ':';
                memcpy(joined + a_len + 1, b, b_len + 1);
                result = JS_NewStringLen(ctx, joined, a_len + 1 + b_len);
            } else {
                result = JS_ThrowOutOfMemory(ctx);
            }
            free(a);
            free(b);
            free(joined);
            goto done;
        }
    } else if (lan_crypto_aes_block(cbc, encrypt, key, key_len, iv, data, data_len, out)) {
        result = throw_msg(ctx, "aes-%s failed", mode);
        goto done;
    }
    result = new_b64(ctx, out, data_len);
    goto done;
fail:
    result = thrown;
done:
    free(mode);
    free(key);
    free(iv);
    free(data);
    free(aad);
    free(tag);
    free(out);
    return result;
}

static bool hash_alg(const char *name, lan_hash_t *alg)
{
    if (strcmp(name, "md5") == 0) *alg = LAN_HASH_MD5;
    else if (strcmp(name, "sha1") == 0) *alg = LAN_HASH_SHA1;
    else if (strcmp(name, "sha256") == 0) *alg = LAN_HASH_SHA256;
    else return false;
    return true;
}

// __hash(algorithm, data) and __hmac(algorithm, key, data): md5, sha1 or sha256.
static JSValue hash_or_hmac(JSContext *ctx, int argc, JSValue *argv, bool hmac)
{
    JSValue thrown = JS_UNDEFINED, result;
    size_t name_len, key_len = 0, data_len = 0;
    bool present;
    uint8_t *key = NULL, *data = NULL, digest[32];
    lan_hash_t alg;
    char *name = arg_copy(ctx, argc, argv, 0, "algorithm", &name_len, &present, &thrown);
    if (!name) return JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "algorithm is required") : thrown;
    if (!hash_alg(name, &alg)) {
        free(name);
        return JS_ThrowTypeError(ctx, "algorithm must be md5, sha1 or sha256");
    }
    free(name);
    if (hmac && !(key = arg_bytes(ctx, argc, argv, 1, "key", false, &key_len, &present, &thrown)) &&
        !JS_IsUndefined(thrown))
        return thrown;
    data = arg_bytes(ctx, argc, argv, hmac ? 2 : 1, "data", false, &data_len, &present, &thrown);
    if (!JS_IsUndefined(thrown)) {
        free(key);
        return thrown;
    }
    int rc = hmac ? lan_crypto_hmac(alg, key, key_len, data, data_len, digest)
                  : lan_crypto_hash(alg, data, data_len, digest);
    result = rc ? throw_msg(ctx, "hash failed") : new_b64(ctx, digest, lan_crypto_hash_len(alg));
    free(key);
    free(data);
    return result;
}

static JSValue js_lan_hash(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return hash_or_hmac(ctx, argc, argv, false);
}

static JSValue js_lan_hmac(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    return hash_or_hmac(ctx, argc, argv, true);
}

static JSValue js_lan_random(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    int n;
    if (argc < 1 || JS_ToInt32(ctx, &n, argv[0])) return JS_ThrowTypeError(ctx, "n must be a number");
    if (n < 0 || n > MAX_RANDOM) return JS_ThrowRangeError(ctx, "n must be 0 to %d", MAX_RANDOM);
    uint8_t *buf = malloc((size_t)n + 1);
    if (!buf) return JS_ThrowOutOfMemory(ctx);
    JSValue v = lan_crypto_random(buf, (size_t)n) ? throw_msg(ctx, "no random bytes") : new_b64(ctx, buf, (size_t)n);
    free(buf);
    return v;
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// An index argument of slice: negative counts from the end, as Array.prototype.slice.
static size_t slice_index(JSContext *ctx, int argc, JSValue *argv, int i, size_t len, size_t missing)
{
    double d;
    if (i >= argc || JS_IsUndefined(argv[i])) return missing;
    if (JS_ToNumber(ctx, &d, argv[i]) || d != d) return 0;
    if (d < 0) d += (double)len;
    if (d < 0) return 0;
    return d > (double)len ? len : (size_t)d;
}

// __bytes(op, a, b, c): fromText, toText, fromHex, toHex, concat, slice, length.
static JSValue js_lan_bytes(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    JSValue thrown = JS_UNDEFINED, result = JS_UNDEFINED;
    size_t op_len, len = 0, len2 = 0;
    bool present;
    uint8_t *a = NULL, *b = NULL, *out = NULL;
    char *text = NULL;
    char *op = arg_copy(ctx, argc, argv, 0, "op", &op_len, &present, &thrown);
    if (!op) return JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "op is required") : thrown;
    if (strcmp(op, "fromText") == 0 || strcmp(op, "fromHex") == 0) {
        if (!(text = arg_copy(ctx, argc, argv, 1, "text", &len, &present, &thrown))) {
            result = JS_IsUndefined(thrown) ? JS_ThrowTypeError(ctx, "text is required") : thrown;
            goto done;
        }
        if (len > MAX_BYTES_ARG) {
            result = JS_ThrowRangeError(ctx, "longer than %d bytes", MAX_BYTES_ARG);
        } else if (op[4] == 'T') {
            result = new_b64(ctx, (const uint8_t *)text, len);
        } else if (len % 2) {
            result = JS_ThrowTypeError(ctx, "hex must have an even number of digits");
        } else if (!(out = malloc(len / 2 + 1))) {
            result = JS_ThrowOutOfMemory(ctx);
        } else {
            for (size_t i = 0; i < len; i += 2) {
                int hi = hex_value(text[i]), lo = hex_value(text[i + 1]);
                if (hi < 0 || lo < 0) {
                    result = JS_ThrowTypeError(ctx, "not a hex string");
                    goto done;
                }
                out[i / 2] = (uint8_t)(hi << 4 | lo);
            }
            result = new_b64(ctx, out, len / 2);
        }
        goto done;
    }
    if (!(a = arg_bytes(ctx, argc, argv, 1, "data", false, &len, &present, &thrown)) && !JS_IsUndefined(thrown)) {
        result = thrown;
        goto done;
    }
    if (strcmp(op, "toText") == 0) {
        size_t clean_len;
        if (!(text = utf8_clean(a ? a : (const uint8_t *)"", len, &clean_len))) result = JS_ThrowOutOfMemory(ctx);
        else result = JS_NewStringLen(ctx, text, clean_len);
    } else if (strcmp(op, "toHex") == 0) {
        static const char digits[] = "0123456789abcdef";
        if (!(text = malloc(len * 2 + 1))) {
            result = JS_ThrowOutOfMemory(ctx);
        } else {
            for (size_t i = 0; i < len; i++) {
                text[2 * i] = digits[a[i] >> 4];
                text[2 * i + 1] = digits[a[i] & 15];
            }
            result = JS_NewStringLen(ctx, text, len * 2);
        }
    } else if (strcmp(op, "length") == 0) {
        result = JS_NewInt32(ctx, (int32_t)len);
    } else if (strcmp(op, "slice") == 0) {
        size_t start = slice_index(ctx, argc, argv, 2, len, 0), end = slice_index(ctx, argc, argv, 3, len, len);
        result = new_b64(ctx, a ? a + start : a, end > start ? end - start : 0);
    } else if (strcmp(op, "concat") == 0) {
        if (!(b = arg_bytes(ctx, argc, argv, 2, "data", false, &len2, &present, &thrown)) && !JS_IsUndefined(thrown)) {
            result = thrown;
        } else if (len + len2 > MAX_BYTES_ARG) {
            result = JS_ThrowRangeError(ctx, "longer than %d bytes", MAX_BYTES_ARG);
        } else if (!(out = malloc(len + len2 + 1))) {
            result = JS_ThrowOutOfMemory(ctx);
        } else {
            if (len) memcpy(out, a, len);
            if (len2) memcpy(out + len, b, len2);
            result = new_b64(ctx, out, len + len2);
        }
    } else {
        result = JS_ThrowTypeError(ctx, "unknown bytes operation");
    }
done:
    free(op);
    free(text);
    free(a);
    free(b);
    free(out);
    return result;
}

// __log(line): one console.log line, kept until the bound.
static JSValue js_lan_log(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    JSValue thrown = JS_UNDEFINED;
    size_t len;
    bool present;
    char *line = arg_copy(ctx, argc, argv, 0, "line", &len, &present, &thrown);
    if (!line) return JS_IsUndefined(thrown) ? JS_UNDEFINED : thrown;
    sbuf_t entry = {0};
    sb_json(&entry, line, len);
    free(line);
    if (entry.oom) return JS_ThrowOutOfMemory(ctx);
    if (run->logs.len + entry.len + 1 > run->limits->max_log_bytes) {
        run->logs_truncated = true;
    } else {
        if (run->logs.len) sb_put(&run->logs, ",", 1);
        sb_put(&run->logs, entry.buf, entry.len);
    }
    free(entry.buf);
    return JS_UNDEFINED;
}

// __sleep(ms): until ms have passed or the deadline, whichever is first.
static JSValue js_lan_sleep(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    double ms;
    if (argc < 1 || JS_ToNumber(ctx, &ms, argv[0]) || ms != ms) return JS_ThrowTypeError(ctx, "ms must be a number");
    int64_t now = run->host->monotonic_ms(run->host->ctx);
    int64_t left = run->limits->deadline_ms - now;
    if (ms > (double)left) ms = (double)left;
    while (ms > 0 && !interrupt(ctx, run)) {
        uint32_t step = ms > 100 ? 100 : (uint32_t)ms;
        run->host->sleep_ms(run->host->ctx, step);
        ms -= step;
    }
    return interrupt(ctx, run) ? JS_ThrowInternalError(ctx, "interrupted") : JS_UNDEFINED;
}

// new Date() and new Date(ms): the only forms Micro QuickJS has.
static JSValue js_date_constructor(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    double ms;
    argc &= ~FRAME_CF_CTOR;
    if (argc == 0) {
        ms = (double)run->host->wall_ms(run->host->ctx);
    } else if (argc == 1 && JS_IsNumber(ctx, argv[0])) {
        if (JS_ToNumber(ctx, &ms, argv[0])) return JS_EXCEPTION;
    } else {
        return JS_ThrowTypeError(ctx, "unsupported Date() parameter");
    }
    return JS_NewDate(ctx, ms);
}

static JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    return JS_NewInt64(ctx, run->host->wall_ms(run->host->ctx));
}

static JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    run_t *run = run_of(ctx);
    return JS_NewInt64(ctx, run->host->monotonic_ms(run->host->ctx));
}

#include "lan_script_stdlib.h"
#include "lan_script_prelude.inc"

// ── the run ──

static bool interrupt(JSContext *ctx, void *opaque)
{
    run_t *run = opaque;
    if (run->stopped) return true;
    const char *reason = run->host->cancelled ? run->host->cancelled(run->host->ctx) : NULL;
    if (reason) run->stopped = reason;
    else if (run->host->monotonic_ms(run->host->ctx) >= run->limits->deadline_ms) run->stopped = "the script timed out";
    return run->stopped != NULL;
}

static int interrupt_handler(JSContext *ctx, void *opaque) { return interrupt(ctx, run_of(ctx)); }

static void printed(void *opaque, const void *buf, size_t len)
{
    run_t *run = opaque;
    if (run->printed.len + len <= MAX_ERROR) sb_put(&run->printed, buf, len);
}

// The pending exception, as the engine prints it (name, message and stack).
static void take_exception(JSContext *ctx, run_t *run)
{
    JSValue e = JS_GetException(ctx);
    run->printed.len = 0;
    if (run->printed.buf) run->printed.buf[0] = '\0';
    JS_PrintValueF(ctx, e, JS_DUMP_LONG);
}

static JSValue eval(JSContext *ctx, const char *text, size_t len, const char *name, int flags)
{
    JSValue v = JS_Parse(ctx, text, len, name, flags);
    return JS_IsException(v) ? v : JS_Run(ctx, v);
}

static char *finish(run_t *run, const char *result, size_t result_len, const char *error)
{
    sbuf_t out = {0};
    if (error) {
        sb_str(&out, "{\"error\":");
        sb_json(&out, error, strlen(error));
    } else {
        sb_str(&out, "{\"result\":");
        sb_put(&out, result, result_len);
    }
    sb_str(&out, ",\"logs\":[");
    if (run->logs.len) sb_put(&out, run->logs.buf, run->logs.len);
    sb_str(&out, run->logs_truncated ? "],\"logs_truncated\":true}" : "]}");
    if (out.oom) {
        free(out.buf);
        return NULL;
    }
    return out.buf;
}

char *lan_script_run(const lan_script_host_t *host, const lan_script_limits_t *limits, const char *source,
                     size_t source_len, const char *args_json, size_t args_len)
{
    run_t run = {.host = host, .limits = limits};
    static const char head[] = "__run(function (args) {";
    static const char tail[] = "\n}, __args)";
    char *program = malloc(sizeof(head) + source_len + sizeof(tail));
    if (!program) return NULL;
    size_t program_len = 0;
    memcpy(program, head, sizeof(head) - 1);
    program_len += sizeof(head) - 1;
    memcpy(program + program_len, source, source_len);
    program_len += source_len;
    memcpy(program + program_len, tail, sizeof(tail));
    program_len += sizeof(tail) - 1;

    char *out = NULL;
    if (limits->heap_bytes < MIN_HEAP) {
        free(program);
        return finish(&run, NULL, 0, "not enough memory for the script runtime");
    }
    JSContext *ctx = JS_NewContext(limits->heap, limits->heap_bytes, &lan_script_stdlib);
    if (!ctx) {
        free(program);
        return finish(&run, NULL, 0, "not enough memory for the script runtime");
    }
    JS_SetContextOpaque(ctx, &run);
    JS_SetLogFunc(ctx, printed);
    JS_SetInterruptHandler(ctx, interrupt_handler);

    JSValue v = eval(ctx, LAN_SCRIPT_PRELUDE, sizeof(LAN_SCRIPT_PRELUDE) - 1, "prelude", 0);
    if (JS_IsException(v)) {
        take_exception(ctx, &run);
        out = finish(&run, NULL, 0, run.printed.len ? run.printed.buf : "the prelude failed");
        goto done;
    }
    if (!args_json || args_len == 0) args_json = "{}", args_len = 2;
    JSValue args = JS_NewStringLen(ctx, args_json, args_len);
    if (JS_IsException(args)) {
        out = finish(&run, NULL, 0, "not enough memory for args");
        goto done;
    }
    JS_SetPropertyStr(ctx, JS_GetGlobalObject(ctx), "__args", args);

    v = eval(ctx, program, program_len, "script", JS_EVAL_RETVAL);
    if (JS_IsException(v)) {
        take_exception(ctx, &run);
        out = finish(&run, NULL, 0,
                     run.stopped ? run.stopped : run.printed.len ? run.printed.buf : "the script failed");
        goto done;
    }
    JSCStringBuf tmp;
    size_t len;
    const char *json = JS_ToCStringLen(ctx, &len, v, &tmp);
    if (!json) {
        out = finish(&run, NULL, 0, "the result could not be read");
    } else if (len > limits->max_result_bytes) {
        char error[96];
        snprintf(error, sizeof(error), "the result is %u bytes of JSON; at most %u are returned", (unsigned)len,
                 (unsigned)limits->max_result_bytes);
        out = finish(&run, NULL, 0, error);
    } else {
        out = finish(&run, json, len, NULL);
    }
done:
    JS_FreeContext(ctx);
    free(program);
    free(run.logs.buf);
    free(run.printed.buf);
    return out;
}
