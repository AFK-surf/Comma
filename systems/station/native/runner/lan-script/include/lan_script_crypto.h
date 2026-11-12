// SPDX-License-Identifier: Apache-2.0
#pragma once

// The crypto a LAN script's crypto.* calls (lan_script.c), from the platform's library: PSA Crypto in the
// firmware (lan_script_crypto_psa.c), RustCrypto in the station's runner. Each returns 0 on success;
// anything else leaves out unspecified. Lengths are checked by lan_script.c before the call.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { LAN_HASH_MD5, LAN_HASH_SHA1, LAN_HASH_SHA256 } lan_hash_t;

// Digest length of alg: 16, 20 or 32.
size_t lan_crypto_hash_len(lan_hash_t alg);
int lan_crypto_hash(lan_hash_t alg, const uint8_t *in, size_t len, uint8_t *out);
int lan_crypto_hmac(lan_hash_t alg, const uint8_t *key, size_t key_len, const uint8_t *in, size_t len, uint8_t *out);

// AES-ECB (iv NULL) or AES-CBC, without padding: len is a multiple of 16. key_len is 16, 24 or 32.
int lan_crypto_aes_block(bool cbc, bool encrypt, const uint8_t *key, size_t key_len, const uint8_t *iv,
                         const uint8_t *in, size_t len, uint8_t *out);
// AES-GCM with a 16-byte tag: written when encrypting, checked when decrypting (nonzero when it does not
// match). iv_len is 12.
int lan_crypto_aes_gcm(bool encrypt, const uint8_t *key, size_t key_len, const uint8_t *iv, size_t iv_len,
                       const uint8_t *aad, size_t aad_len, const uint8_t *in, size_t len, uint8_t *out,
                       uint8_t tag[16]);
int lan_crypto_random(uint8_t *out, size_t len);
