/*
 * pick_random_reference.c: draw one vendored design reference at random.
 *
 * Run with script.run_file. Optional env SEED makes the draw reproducible
 * (FNV-1a over the seed bytes, as the earlier JavaScript picker did); without
 * a seed the draw comes from the clock. The result is set with script.result:
 * {"slug": "<name>", "reference_count": 68, "seed": "<seed>"?}.
 *
 * The slugs live in one newline-separated literal scanned for the n-th
 * line, which keeps the table a single read-only string; the buffers are
 * static globals (script.sdk: 4 KiB stack frames, no heap).
 */
#include "spinfoam.h"

#define SLUG_COUNT 68u

static const char SLUGS[] =
    "airbnb\nairtable\napple\nbinance\nbmw\nbugatti\ncal\nclaude\nclay\nclickhouse\n"
    "cohere\ncoinbase\ncomposio\ncursor\nelevenlabs\nexpo\nferrari\nfigma\nframer\n"
    "hashicorp\nibm\nintercom\nkraken\nlamborghini\nlinear.app\nlovable\nmastercard\n"
    "meta\nminimax\nmintlify\nmiro\nmistral.ai\nmongodb\nnike\nnotion\nnvidia\nollama\n"
    "opencode.ai\npinterest\nplaystation\nposthog\nraycast\nrenault\nreplicate\nresend\n"
    "revolut\nrunwayml\nsanity\nsentry\nshopify\nspacex\nspotify\nstripe\nsupabase\n"
    "superhuman\ntesla\ntheverge\ntogether.ai\nuber\nvercel\nvodafone\nvoltagent\nwarp\n"
    "webflow\nwired\nwise\nx.ai\nzapier\n";

static char seed_buf[128];
static char slug_buf[64];

SF_MAIN sf_i64 main(void) {
    char *seed = seed_buf;
    char *slug = slug_buf;
    const char *slugs = SLUGS;
    sf_i64 seed_len = 0;

    sf_handle config = sf_config();
    if (config < 0) return 10;
    sf_handle env = sf_json_get(config, "env");
    if (env >= 0) {
        sf_handle value = sf_json_get(env, "SEED");
        if (value >= 0) {
            seed_len = sf_json_read_string(value, seed, sizeof(seed_buf));
            sf_drop(value);
        }
        sf_drop(env);
    }
    sf_drop(config);
    if (seed_len < 0 || seed_len > (sf_i64)sizeof(seed_buf)) seed_len = 0;

    unsigned int index;
    if (seed_len > 0) {
        unsigned int hash = 2166136261u;
        for (sf_i64 i = 0; i < seed_len; ++i) {
            hash ^= (unsigned char)seed[i];
            hash *= 16777619u;
        }
        index = hash % SLUG_COUNT;
    } else {
        index = (unsigned int)(sf_now_unix_ms() % SLUG_COUNT);
    }

    unsigned int line = 0;
    sf_u64 start = 0, i = 0;
    for (; slugs[i]; ++i) {
        if (slugs[i] == '\n') {
            if (line == index) break;
            line++;
            start = i + 1;
        }
    }
    sf_u64 len = i - start;
    if (len == 0 || len >= sizeof(slug_buf)) return 11;
    memcpy(slug, slugs + start, len);

    sf_handle result = sf_json_object();
    sf_handle v = sf_json_string_raw(slug, len);
    sf_json_set(result, "slug", v);
    sf_drop(v);
    v = sf_json_number(SLUG_COUNT);
    sf_json_set(result, "reference_count", v);
    sf_drop(v);
    if (seed_len > 0) {
        v = sf_json_string_raw(seed, seed_len);
        sf_json_set(result, "seed", v);
        sf_drop(v);
    }

    sf_handle args = sf_json_object();
    sf_json_set(args, "value", result);
    sf_drop(result);
    sf_handle stored = sf_host_call("script.result", args, 5000);
    sf_drop(args);
    if (stored < 0) return stored;
    sf_drop(stored);
    return 0;
}
