// SPDX-License-Identifier: Apache-2.0
#pragma once

// LAN scripts: a JavaScript function (Micro QuickJS, ES5 strict) that a gateway runs on its own network,
// for device protocols that take more than one request (docs/lan-script.md). The script reaches the
// network only through the gateway's own LAN methods, and computes with the bytes and crypto helpers.
//
// The same runtime is built into the firmware (lan_script_crypto_psa.c) and into the computer
// station's runner (Cue: systems/station/native/runner, its crypto in Rust). Both report
// LAN_SCRIPT_API; a change to what a script sees raises it.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LAN_SCRIPT_API 2

typedef struct {
    // Runs one LAN method of this gateway ("http_request", "udp_request", "tcp_request" or "lan_discover") with params
    // as JSON text, as the Connector would. True: *out is the result as JSON text. False: *out is the
    // error message. *out is malloc'd and freed by the caller; NULL when out of memory.
    bool (*call)(void *ctx, const char *method, const char *params, size_t params_len, char **out);
    // Milliseconds since the epoch (Date.now) and of a monotonic clock (deadline, performance.now).
    int64_t (*wall_ms)(void *ctx);
    int64_t (*monotonic_ms)(void *ctx);
    void (*sleep_ms)(void *ctx, uint32_t ms);
    // Non-NULL: stop the script with this reason (access turned off, the socket closed). May be NULL.
    const char *(*cancelled)(void *ctx);
    void *ctx;
} lan_script_host_t;

typedef struct {
    // The script's whole memory: Micro QuickJS allocates nothing else.
    void *heap;
    size_t heap_bytes;
    // On the monotonic clock: the script stops there, also inside sleep().
    int64_t deadline_ms;
    // Longest JSON of the return value, and of all console.log lines together.
    size_t max_result_bytes;
    size_t max_log_bytes;
} lan_script_limits_t;

// Runs `source` as the body of `function (args) { … }`, args being args_json parsed (NULL or empty: {}).
// Returns malloc'd JSON text, NUL-terminated, with the value the function returned or why it failed:
//   {"result":<value>,"logs":["…"]}  or  {"error":"…","logs":["…"]}
// plus "logs_truncated":true when lines were dropped. NULL only when out of memory.
char *lan_script_run(const lan_script_host_t *host, const lan_script_limits_t *limits, const char *source,
                     size_t source_len, const char *args_json, size_t args_len);
