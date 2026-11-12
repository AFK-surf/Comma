#include <erl_nif.h>
#include <lean/lean.h>
#include <lean/mimalloc.h>
#include <openssl/evp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 33))
#include <malloc.h>
#define VERIFIED_KERNEL_MALLINFO2 1
#endif

/* SHA-256 for `VerifiedKernel.ByteDigest.sha256Bytes`, from OpenSSL libcrypto.
 * The Lean side borrows `message`; the 32-byte digest is a fresh ByteArray. */
lean_obj_res salix_verified_kernel_sha256(b_lean_obj_arg message) {
    lean_object *digest = lean_alloc_sarray(1, 32, 32);
    unsigned int size = 0;
    if (!EVP_Digest(lean_sarray_cptr(message), lean_sarray_size(message),
                    lean_sarray_cptr(digest), &size, EVP_sha256(), NULL) || size != 32) {
        lean_dec(digest);
        lean_internal_panic("OpenSSL SHA-256 failed");
    }
    return digest;
}

extern void lean_initialize_runtime_module(void);
extern void lean_initialize_thread(void);
extern void lean_finalize_thread(void);
extern lean_object *initialize_verified__kernel_VerifiedKernel_Native(uint8_t);
extern lean_obj_res salix_verified_kernel_invoke(lean_obj_arg);
extern lean_obj_res salix_verified_kernel_session(lean_obj_arg, lean_obj_arg);
extern lean_obj_res salix_verified_kernel_terminal_new(uint32_t, uint32_t);
extern lean_obj_res salix_verified_kernel_terminal_feed(lean_obj_arg, lean_obj_arg);
extern lean_obj_res salix_verified_kernel_terminal_resize(lean_obj_arg, uint32_t, uint32_t);
extern lean_obj_res salix_verified_kernel_terminal_snapshot(lean_obj_arg);
extern uint8_t salix_verified_kernel_terminal_app_cursor(lean_obj_arg);

/* Every resident state derived from one admitted state (through steps,
 * queries, forks) shares Lean objects with it, and no object is reachable
 * from two lineages: a call touches one resident and data it decodes. A
 * lineage lock serializes every call and every release on one lineage, so
 * the objects keep single-threaded reference counts. Marking the state
 * multi-threaded instead made every count update atomic, which more than
 * doubled the cost of each pass over a long transcript. */
typedef struct lineage {
    ErlNifMutex *mutex;
    ErlNifMutex *pending_mutex;
    lean_object **pending;
    size_t pending_len;
    size_t pending_cap;
    int refs;
    long residents;
    struct lineage *prev;
    struct lineage *next;
} lineage;

/* A Session state that stays resident in the Lean heap. The BEAM holds it
 * through an opaque resource term. */
typedef struct {
    lean_object *term;
    lineage *lineage;
} resident_state;

static ErlNifResourceType *resident_type;

/* A terminal emulator state (`VerifiedKernel.Terminal`). The resource holds
 * the only reference and hands it to each call, so Lean updates the state in
 * place. The mutex serializes calls that share one resource term. */
typedef struct {
    ErlNifMutex *mutex;
    lean_object *state;
} terminal_state;

static ErlNifResourceType *terminal_type;
static ERL_NIF_TERM atom_nil;

/* Live native objects, for `memory_stats/0`. The BEAM accounts a resource
 * term at its struct size, so these counts are the only view of how much
 * Lean heap the live handles keep. */
static long live_residents;
static long live_terminals;
/* Every live lineage, so `memory_stats/0` can report how its residents
 * spread. Only lineage creation, release and that read take the lock. */
static ErlNifMutex *lineages_mutex;
static lineage *lineages_head;

static void count(long *counter, long delta) {
    __atomic_add_fetch(counter, delta, __ATOMIC_RELAXED);
}

static lineage *lineage_new(void) {
    lineage *l = enif_alloc(sizeof(lineage));
    if (!l) return NULL;
    l->mutex = enif_mutex_create("verified_kernel_lineage");
    l->pending_mutex = enif_mutex_create("verified_kernel_lineage_pending");
    l->pending = NULL;
    l->pending_len = 0;
    l->pending_cap = 0;
    l->refs = 1;
    l->residents = 0;
    l->prev = NULL;
    if (!l->mutex || !l->pending_mutex) {
        if (l->mutex) enif_mutex_destroy(l->mutex);
        if (l->pending_mutex) enif_mutex_destroy(l->pending_mutex);
        enif_free(l);
        return NULL;
    }
    enif_mutex_lock(lineages_mutex);
    l->next = lineages_head;
    if (lineages_head) lineages_head->prev = l;
    lineages_head = l;
    enif_mutex_unlock(lineages_mutex);
    return l;
}

static lineage *lineage_retain(lineage *l) {
    enif_mutex_lock(l->pending_mutex);
    l->refs++;
    enif_mutex_unlock(l->pending_mutex);
    return l;
}

/* Releases the objects whose owners were collected while the lineage was
 * busy. Runs on a Lean-initialized thread with the lineage lock held, or
 * when no resident of the lineage remains. */
static void lineage_drain(lineage *l) {
    for (;;) {
        enif_mutex_lock(l->pending_mutex);
        lean_object **objects = l->pending;
        size_t count = l->pending_len;
        l->pending = NULL;
        l->pending_len = 0;
        l->pending_cap = 0;
        enif_mutex_unlock(l->pending_mutex);
        if (!objects) return;
        for (size_t i = 0; i < count; i++) lean_dec(objects[i]);
        enif_free(objects);
    }
}

static void lineage_defer(lineage *l, lean_object *term) {
    enif_mutex_lock(l->pending_mutex);
    if (l->pending_len == l->pending_cap) {
        size_t cap = l->pending_cap ? l->pending_cap * 2 : 8;
        lean_object **grown = enif_realloc(l->pending, cap * sizeof(lean_object *));
        if (!grown) {
            /* Out of memory: the object stays allocated rather than racing. */
            enif_mutex_unlock(l->pending_mutex);
            return;
        }
        l->pending = grown;
        l->pending_cap = cap;
    }
    l->pending[l->pending_len++] = term;
    enif_mutex_unlock(l->pending_mutex);
}

static void lineage_release(lineage *l) {
    enif_mutex_lock(l->pending_mutex);
    int remaining = --l->refs;
    enif_mutex_unlock(l->pending_mutex);
    if (remaining > 0) return;
    enif_mutex_lock(lineages_mutex);
    if (l->prev) l->prev->next = l->next;
    else lineages_head = l->next;
    if (l->next) l->next->prev = l->prev;
    enif_mutex_unlock(lineages_mutex);
    /* No resident and no call references the lineage: nothing can contend. */
    if (l->pending_len) {
        lean_initialize_thread();
        lineage_drain(l);
        lean_finalize_thread();
    }
    enif_mutex_destroy(l->mutex);
    enif_mutex_destroy(l->pending_mutex);
    enif_free(l);
}

/* A resource destructor runs on whichever scheduler collects the term and
 * must not block: while a call holds the lineage, the release is deferred
 * to that call. */
static void resident_destroy(ErlNifEnv *env, void *object) {
    (void)env;
    resident_state *state = object;
    lineage *l = state->lineage;
    if (state->term) {
        count(&live_residents, -1);
        count(&l->residents, -1);
        if (enif_mutex_trylock(l->mutex) == 0) {
            lean_initialize_thread();
            lean_dec(state->term);
            lineage_drain(l);
            lean_finalize_thread();
            enif_mutex_unlock(l->mutex);
        } else {
            lineage_defer(l, state->term);
        }
    }
    lineage_release(l);
}

/* session_release(resident) -> ok
 * Drops the state behind a handle now, without waiting for the VM to
 * collect the handle. The handle keeps its lineage until it is collected;
 * a later call with it is a badarg. Released twice is a no-op. */
static ERL_NIF_TERM session_release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    resident_state *state;
    if (argc != 1 || !enif_get_resource(env, argv[0], resident_type, (void **)&state))
        return enif_make_badarg(env);
    lineage *l = state->lineage;
    enif_mutex_lock(l->mutex);
    if (state->term) {
        lean_initialize_thread();
        lean_dec(state->term);
        state->term = NULL;
        lineage_drain(l);
        lean_finalize_thread();
        count(&live_residents, -1);
        count(&l->residents, -1);
    }
    enif_mutex_unlock(l->mutex);
    return enif_make_atom(env, "ok");
}

static void terminal_destroy(ErlNifEnv *env, void *object) {
    (void)env;
    terminal_state *terminal = object;
    count(&live_terminals, -1);
    if (terminal->state) {
        lean_initialize_thread();
        lean_dec(terminal->state);
        lean_finalize_thread();
    }
    if (terminal->mutex) enif_mutex_destroy(terminal->mutex);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    resident_type = enif_open_resource_type(env, NULL, "verified_kernel_session_state",
                                            resident_destroy, ERL_NIF_RT_CREATE, NULL);
    if (!resident_type) return -1;
    terminal_type = enif_open_resource_type(env, NULL, "verified_kernel_terminal_state",
                                            terminal_destroy, ERL_NIF_RT_CREATE, NULL);
    if (!terminal_type) return -1;
    lineages_mutex = enif_mutex_create("verified_kernel_lineages");
    if (!lineages_mutex) return -1;
    atom_nil = enif_make_atom(env, "nil");
    lean_initialize_runtime_module();
    /* Initialize the executable dispatcher. Proof tooling is not part of the NIF runtime. */
    lean_object *result = initialize_verified__kernel_VerifiedKernel_Native(1);
    int ok = lean_io_result_is_ok(result);
    lean_dec(result);
    if (!ok) return -1;
    lean_io_mark_end_initialization();
    lean_finalize_thread();
    return 0;
}

static lean_object *copy_input(const ErlNifBinary *input) {
    lean_object *bytes = lean_alloc_sarray(1, input->size, input->size);
    if (input->size) memcpy(lean_sarray_cptr(bytes), input->data, input->size);
    return bytes;
}

/* Consumes output. */
static int copy_output(ErlNifEnv *env, lean_object *output, ERL_NIF_TERM *term) {
    size_t size = lean_sarray_size(output);
    ErlNifBinary binary;
    if (!enif_alloc_binary(size, &binary)) {
        lean_dec(output);
        return 0;
    }
    if (size) memcpy(binary.data, lean_sarray_cptr(output), size);
    lean_dec(output);
    *term = enif_make_binary(env, &binary);
    return 1;
}

static ERL_NIF_TERM invoke(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary input;
    if (argc != 1 || !enif_inspect_binary(env, argv[0], &input))
        return enif_make_badarg(env);

    lean_initialize_thread();
    /* The exported function consumes bytes. Only output remains owned here. */
    lean_object *output = salix_verified_kernel_invoke(copy_input(&input));
    ERL_NIF_TERM term;
    int ok = copy_output(env, output, &term);
    lean_finalize_thread();
    if (!ok) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    return term;
}

/* session(resident | nil, request_bytes) -> {resident | nil, response_bytes} */
static ERL_NIF_TERM session(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary input;
    resident_state *current = NULL;
    if (argc != 2 || !enif_inspect_binary(env, argv[1], &input))
        return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], resident_type, (void **)&current)) {
        if (!enif_is_identical(argv[0], atom_nil)) return enif_make_badarg(env);
        current = NULL;
    }

    lineage *l = current ? lineage_retain(current->lineage) : lineage_new();
    if (!l) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    enif_mutex_lock(l->mutex);
    if (current && !current->term) {
        enif_mutex_unlock(l->mutex);
        lineage_release(l);
        return enif_make_badarg(env);
    }
    lean_initialize_thread();
    lean_object *resident = lean_box(0);
    if (current) {
        lean_inc(current->term);
        resident = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(resident, 0, current->term);
    }
    /* The exported function consumes both arguments. */
    lean_object *reply = salix_verified_kernel_session(resident, copy_input(&input));
    lean_object *next = lean_ctor_get(reply, 0);
    lean_object *output = lean_ctor_get(reply, 1);
    lean_inc(next);
    lean_inc(output);
    lean_dec(reply);

    ERL_NIF_TERM handle = atom_nil;
    if (!lean_is_scalar(next) && current && lean_ctor_get(next, 0) == current->term) {
        /* A read (query, get, persist, export) returns the state it was given.
         * The caller's handle already holds it: a new handle would only be an
         * alias that keeps this revision alive until the caller collects. */
        lean_dec(next);
        handle = argv[0];
    } else if (!lean_is_scalar(next)) {
        lean_object *term = lean_ctor_get(next, 0);
        lean_inc(term);
        lean_dec(next);
        resident_state *stored = enif_alloc_resource(resident_type, sizeof(resident_state));
        stored->term = term;
        stored->lineage = lineage_retain(l);
        count(&live_residents, 1);
        count(&l->residents, 1);
        handle = enif_make_resource(env, stored);
        enif_release_resource(stored);
    }
    ERL_NIF_TERM binary;
    int ok = copy_output(env, output, &binary);
    lineage_drain(l);
    lean_finalize_thread();
    enif_mutex_unlock(l->mutex);
    lineage_release(l);
    if (!ok) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    return enif_make_tuple2(env, handle, binary);
}

/* terminal_new(cols, rows) -> terminal */
static ERL_NIF_TERM terminal_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    unsigned int cols, rows;
    if (argc != 2 || !enif_get_uint(env, argv[0], &cols) || !enif_get_uint(env, argv[1], &rows))
        return enif_make_badarg(env);
    terminal_state *terminal = enif_alloc_resource(terminal_type, sizeof(terminal_state));
    if (!terminal) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    terminal->state = NULL;
    count(&live_terminals, 1);
    terminal->mutex = enif_mutex_create("verified_kernel_terminal");
    if (!terminal->mutex) {
        enif_release_resource(terminal);
        return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    }
    lean_initialize_thread();
    terminal->state = salix_verified_kernel_terminal_new(cols, rows);
    lean_finalize_thread();
    ERL_NIF_TERM handle = enif_make_resource(env, terminal);
    enif_release_resource(terminal);
    return handle;
}

/* Locks the terminal named by argv[0]; NULL when it is not a terminal. */
static terminal_state *terminal_lock(ErlNifEnv *env, ERL_NIF_TERM term) {
    terminal_state *terminal = NULL;
    if (!enif_get_resource(env, term, terminal_type, (void **)&terminal)) return NULL;
    enif_mutex_lock(terminal->mutex);
    lean_initialize_thread();
    return terminal;
}

static void terminal_unlock(terminal_state *terminal) {
    lean_finalize_thread();
    enif_mutex_unlock(terminal->mutex);
}

/* terminal_feed(terminal, bytes) -> replies */
static ERL_NIF_TERM terminal_feed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary input;
    if (argc != 2 || !enif_inspect_binary(env, argv[1], &input)) return enif_make_badarg(env);
    terminal_state *terminal = terminal_lock(env, argv[0]);
    if (!terminal) return enif_make_badarg(env);
    /* The call consumes the state and returns the next one with the replies. */
    lean_object *pair = salix_verified_kernel_terminal_feed(terminal->state, copy_input(&input));
    terminal->state = lean_ctor_get(pair, 0);
    lean_object *replies = lean_ctor_get(pair, 1);
    lean_inc(terminal->state);
    lean_inc(replies);
    lean_dec(pair);
    ERL_NIF_TERM binary;
    int ok = copy_output(env, replies, &binary);
    terminal_unlock(terminal);
    if (!ok) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    return binary;
}

/* terminal_resize(terminal, cols, rows) -> :ok */
static ERL_NIF_TERM terminal_resize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    unsigned int cols, rows;
    if (argc != 3 || !enif_get_uint(env, argv[1], &cols) || !enif_get_uint(env, argv[2], &rows))
        return enif_make_badarg(env);
    terminal_state *terminal = terminal_lock(env, argv[0]);
    if (!terminal) return enif_make_badarg(env);
    terminal->state = salix_verified_kernel_terminal_resize(terminal->state, cols, rows);
    terminal_unlock(terminal);
    return enif_make_atom(env, "ok");
}

/* terminal_snapshot(terminal) -> ETF bytes of the screen */
static ERL_NIF_TERM terminal_snapshot(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    terminal_state *terminal = terminal_lock(env, argv[0]);
    if (!terminal) return enif_make_badarg(env);
    /* A read keeps the resource's reference. */
    lean_inc(terminal->state);
    lean_object *output = salix_verified_kernel_terminal_snapshot(terminal->state);
    ERL_NIF_TERM binary;
    int ok = copy_output(env, output, &binary);
    terminal_unlock(terminal);
    if (!ok) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    return binary;
}

/* terminal_app_cursor(terminal) -> boolean */
static ERL_NIF_TERM terminal_app_cursor(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    terminal_state *terminal = terminal_lock(env, argv[0]);
    if (!terminal) return enif_make_badarg(env);
    lean_inc(terminal->state);
    uint8_t app = salix_verified_kernel_terminal_app_cursor(terminal->state);
    terminal_unlock(terminal);
    return enif_make_atom(env, app ? "true" : "false");
}

static int compare_long(const void *a, const void *b) {
    long x = *(const long *)a, y = *(const long *)b;
    return (x > y) - (x < y);
}

/* Nearest-rank percentile of sorted values. */
static long percentile(const long *sorted, size_t n, unsigned int pct) {
    return n ? sorted[(n * pct + 99) / 100 - 1] : 0;
}

/* Bytes of a mapping that are in physical memory, from mincore(2). */
static size_t resident_bytes(void *base, size_t size) {
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) return 0;
    size_t pages = (size + (size_t)page - 1) / (size_t)page;
    unsigned char *vec = enif_alloc(pages);
    if (!vec) return 0;
    size_t resident = 0;
    if (mincore(base, size, (void *)vec) == 0) {
        for (size_t i = 0; i < pages; i++) resident += vec[i] & 1;
    }
    enif_free(vec);
    return resident * (size_t)page;
}

/* memory_stats() -> map of live native objects and C heap bytes */
static ERL_NIF_TERM memory_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argv;
    if (argc != 0) return enif_make_badarg(env);
    /* A lineage holds Lean objects only while it has a resident. After its
     * last resident is released it stays listed, empty, until the VM collects
     * the handles that still point to it. */
    long *spread = NULL;
    size_t listed = 0, spread_len = 0;
    enif_mutex_lock(lineages_mutex);
    for (lineage *l = lineages_head; l; l = l->next) listed++;
    if (listed) spread = enif_alloc(listed * sizeof(long));
    if (spread) {
        for (lineage *l = lineages_head; l; l = l->next) {
            long residents = __atomic_load_n(&l->residents, __ATOMIC_RELAXED);
            if (residents > 0) spread[spread_len++] = residents;
        }
    }
    enif_mutex_unlock(lineages_mutex);
    if (listed && !spread) return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    if (spread) qsort(spread, spread_len, sizeof(long), compare_long);

    const char *names[14];
    ERL_NIF_TERM values[14];
    size_t n = 0;
#define STAT(name, value)                                    \
    do {                                                     \
        names[n] = (name);                                   \
        values[n] = enif_make_int64(env, (ErlNifSInt64)(value)); \
        n++;                                                 \
    } while (0)
    STAT("residents", __atomic_load_n(&live_residents, __ATOMIC_RELAXED));
    STAT("lineages", spread_len);
    STAT("released_lineages", listed - spread_len);
    STAT("terminals", __atomic_load_n(&live_terminals, __ATOMIC_RELAXED));
    /* Residents per lineage that holds a state. A lineage needs only its
     * current revision; more mean older revisions are still held. */
    STAT("lineage_residents_p50", percentile(spread, spread_len, 50));
    STAT("lineage_residents_p99", percentile(spread, spread_len, 99));
    STAT("lineage_residents_max", spread_len ? spread[spread_len - 1] : 0);
    if (spread) enif_free(spread);
    /* The Lean heap. Lean allocates every object through the embedded
     * mimalloc, which reserves address space in arenas, commits it eagerly
     * where the OS overcommits, and returns purged pages to the OS. The
     * release build keeps no object totals. The resident pages of the
     * arenas are the measure of the heap: the Lean objects plus freed pages
     * mimalloc has not purged yet; memory mapped from the OS outside the
     * arenas is not counted. mimalloc's own commit counter
     * (mi_process_info) is not a measure of it: it read below zero on
     * production nodes. */
    size_t lean_reserved = 0, lean_resident = 0;
    for (mi_arena_id_t id = 1;; id++) {
        size_t size = 0;
        void *base = mi_arena_area(id, &size);
        if (!base) break;
        lean_reserved += size;
        lean_resident += resident_bytes(base, size);
    }
    STAT("lean_reserved_bytes", lean_reserved);
    STAT("lean_resident_bytes", lean_resident);
#ifdef VERIFIED_KERNEL_MALLINFO2
    /* The process-wide glibc heap of other native code, outside the Lean
     * heap and the ERTS carriers. */
    struct mallinfo2 info = mallinfo2();
    STAT("malloc_arena_bytes", info.arena);
    STAT("malloc_mmap_bytes", info.hblkhd);
    STAT("malloc_in_use_bytes", info.uordblks);
    STAT("malloc_free_bytes", info.fordblks);
    STAT("malloc_releasable_bytes", info.keepcost);
#endif
#undef STAT
    ERL_NIF_TERM keys[14];
    for (size_t i = 0; i < n; i++) keys[i] = enif_make_atom(env, names[i]);
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, values, n, &map);
    return map;
}

static ErlNifFunc functions[] = {
    {"invoke_etf", 1, invoke, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"session", 2, session, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"session_release", 1, session_release, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"terminal_new", 2, terminal_new, 0},
    {"terminal_feed", 2, terminal_feed, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"terminal_resize", 3, terminal_resize, 0},
    {"terminal_snapshot", 1, terminal_snapshot, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"terminal_app_cursor", 1, terminal_app_cursor, 0},
    {"memory_stats", 0, memory_stats, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};
ERL_NIF_INIT(Elixir.SalixVerifiedKernel.Native, functions, load, NULL, NULL, NULL)
