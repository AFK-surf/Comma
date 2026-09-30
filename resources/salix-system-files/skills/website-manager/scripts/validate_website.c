/*
 * validate_website.c: validate a website's _api.json.
 *
 * Run with script.run_file and env entries SITE_NAME, WEBSITE_ROOT,
 * API_JSON_PATH and REQUIRE_API_JSON ("true" to require the file). The file is
 * read through salix.call fs.read_file. The result is set with script.result:
 *
 *   {"ok", "site_name", "website_root", "errors", "warnings",
 *    "checks": {"api_json": {"path", "present", "valid_json", "schema_valid"}}}
 *
 * Compiler rules (script.sdk): buffers are static globals (4 KiB stack
 * frames), no sprintf (see append/append_uint), no recursion.
 */
#include "spinfoam.h"

#define TEXT_CAP 512
#define TOOL_ERROR_CAP 1024
#define CONTENT_CAP 16384

static char site_name_buf[TEXT_CAP];
static char website_root_buf[TEXT_CAP];
static char api_path_buf[TEXT_CAP];
static char require_buf[16];
static char message_buf[TEXT_CAP];
static char tool_error_buf[TOOL_ERROR_CAP];
static char content_buf[CONTENT_CAP];

/* ---- results ------------------------------------------------------------- */

static sf_handle errors;
static sf_handle warnings;
static sf_u64 error_count;
static sf_u64 message_len;

static void message_reset(void) { message_len = 0; }

static void append(const char *text) {
    char *message = message_buf;
    sf_u64 n = sf_strlen(text);
    if (message_len + n >= TEXT_CAP) n = TEXT_CAP - 1 - message_len;
    if (n > 0) memcpy(message + message_len, text, n);
    message_len += n;
}

static void append_uint(sf_u64 value) {
    char digits[24];
    char *d = digits;
    sf_u64 n = 0;
    if (value == 0) { d[n++] = '0'; }
    while (value > 0 && n < 20) { d[n++] = (char)('0' + (value % 10u)); value /= 10u; }
    char *message = message_buf;
    while (n > 0 && message_len < TEXT_CAP - 1) { message[message_len++] = d[--n]; }
}

static void push_message(sf_handle list) {
    char *message = message_buf;
    sf_handle text = sf_json_string_raw(message, message_len);
    if (text >= 0) { sf_json_push(list, text); sf_drop(text); }
}

static void add_error(void) { push_message(errors); error_count++; }
static void add_warning(void) { push_message(warnings); }

/* ---- input helpers ------------------------------------------------------- */

/* Reads env[name] into out (capacity cap); returns the length or 0. */
static sf_i64 read_env(sf_handle env, const char *name, char *out, sf_u64 cap) {
    if (env < 0) return 0;
    sf_handle value = sf_json_get(env, name);
    if (value < 0) return 0;
    sf_i64 n = sf_json_read_string(value, out, cap);
    sf_drop(value);
    if (n < 0 || (sf_u64)n > cap) return 0;
    return n;
}

static int text_contains(const char *text, sf_u64 text_len, const char *needle) {
    sf_u64 n = sf_strlen(needle);
    if (n == 0 || text_len < n) return 0;
    for (sf_u64 i = 0; i + n <= text_len; ++i) {
        if (memcmp(text + i, needle, n) == 0) return 1;
    }
    return 0;
}

static int is_object(sf_handle h) { return h >= 0 && sf_json_kind(h) == SF_OBJECT; }
static int is_array(sf_handle h) { return h >= 0 && sf_json_kind(h) == SF_ARRAY; }
static int is_string(sf_handle h) { return h >= 0 && sf_json_kind(h) == SF_STRING; }
static int is_bool(sf_handle h) { return h >= 0 && sf_json_kind(h) == SF_BOOL; }

static int is_non_negative_integer(sf_handle h) {
    sf_i64 value = 0;
    if (h < 0 || sf_json_kind(h) != SF_NUMBER) return 0;
    if (sf_json_i64(h, &value) != 0) return 0;
    return value >= 0;
}

/* ---- validation ---------------------------------------------------------- */

static void validate_string_array(sf_handle value, const char *path) {
    if (!is_array(value)) {
        message_reset(); append(path); append(" must be an array of strings"); add_error();
        return;
    }
    sf_i64 count = sf_bytes_len(value);
    for (sf_i64 i = 0; i < count; ++i) {
        sf_handle item = sf_json_at(value, (sf_u64)i);
        if (!is_string(item)) {
            message_reset(); append(path); append("["); append_uint((sf_u64)i);
            append("] must be a string"); add_error();
        }
        if (item >= 0) sf_drop(item);
    }
}

static void validate_auth(sf_handle parsed) {
    sf_handle auth = sf_json_get(parsed, "auth");
    if (auth < 0) return;
    if (!is_object(auth)) {
        message_reset(); append("auth must be an object"); add_error();
    } else {
        sf_handle tokens = sf_json_get(auth, "bearer_tokens");
        if (tokens >= 0) { validate_string_array(tokens, "auth.bearer_tokens"); sf_drop(tokens); }
    }
    sf_drop(auth);
}

static void validate_rule_operations(sf_handle rule, sf_u64 i) {
    sf_handle operations = sf_json_get(rule, "operations");
    if (operations < 0) return;
    if (!is_array(operations)) {
        message_reset(); append("storage.rules["); append_uint(i); append("].operations must be an array");
        add_error();
    } else {
        sf_i64 count = sf_bytes_len(operations);
        for (sf_i64 j = 0; j < count; ++j) {
            sf_handle op = sf_json_at(operations, (sf_u64)j);
            if (!is_string(op)) {
                message_reset(); append("storage.rules["); append_uint(i); append("].operations[");
                append_uint((sf_u64)j); append("] must be a string"); add_error();
            } else {
                char op_text[16];
                sf_i64 n = sf_json_read_string(op, op_text, sizeof(op_text));
                int known = 0;
                if (n == 4 && memcmp(op_text, "read", 4) == 0) known = 1;
                if (n == 5 && memcmp(op_text, "write", 5) == 0) known = 1;
                if (n == 6 && memcmp(op_text, "delete", 6) == 0) known = 1;
                if (n == 4 && memcmp(op_text, "list", 4) == 0) known = 1;
                if (!known) {
                    message_reset(); append("storage.rules["); append_uint(i); append("].operations[");
                    append_uint((sf_u64)j); append("] must be one of read, write, delete, list");
                    add_error();
                }
            }
            if (op >= 0) sf_drop(op);
        }
    }
    sf_drop(operations);
}

static int operations_include(sf_handle rule, const char *name) {
    sf_handle operations = sf_json_get(rule, "operations");
    int found = 0;
    if (!is_array(operations)) { if (operations >= 0) sf_drop(operations); return 0; }
    sf_i64 count = sf_bytes_len(operations);
    for (sf_i64 j = 0; j < count && !found; ++j) {
        sf_handle op = sf_json_at(operations, (sf_u64)j);
        if (is_string(op)) {
            char op_text[16];
            sf_i64 n = sf_json_read_string(op, op_text, sizeof(op_text));
            sf_u64 want = sf_strlen(name);
            if ((sf_u64)n == want && memcmp(op_text, name, want) == 0) found = 1;
        }
        if (op >= 0) sf_drop(op);
    }
    sf_drop(operations);
    return found;
}

/* True when rule.require_auth is exactly the boolean `expected`. */
static int require_auth_is(sf_handle rule, int expected) {
    sf_handle value = sf_json_get(rule, "require_auth");
    int result = 0;
    if (is_bool(value)) result = (sf_json_bool(value) == 1) == (expected == 1);
    if (value >= 0) sf_drop(value);
    return result;
}

static void validate_rule(sf_handle rules, sf_u64 i, sf_i64 count, int *saw_catch_all) {
    sf_handle rule = sf_json_at(rules, i);
    if (!is_object(rule)) {
        message_reset(); append("storage.rules["); append_uint(i); append("] must be an object");
        add_error();
        if (rule >= 0) sf_drop(rule);
        return;
    }

    sf_handle key_prefix = sf_json_get(rule, "key_prefix");
    if (key_prefix >= 0 && !is_string(key_prefix)) {
        message_reset(); append("storage.rules["); append_uint(i); append("].key_prefix must be a string");
        add_error();
    }

    validate_rule_operations(rule, i);

    sf_handle require_auth = sf_json_get(rule, "require_auth");
    if (require_auth >= 0 && !is_bool(require_auth)) {
        message_reset(); append("storage.rules["); append_uint(i); append("].require_auth must be a boolean");
        add_error();
    }
    if (require_auth >= 0) sf_drop(require_auth);

    sf_handle max_value_size = sf_json_get(rule, "max_value_size");
    if (max_value_size >= 0 && !is_non_negative_integer(max_value_size)) {
        message_reset(); append("storage.rules["); append_uint(i);
        append("].max_value_size must be a non-negative integer"); add_error();
    }
    if (max_value_size >= 0) sf_drop(max_value_size);

    if (is_string(key_prefix) && sf_bytes_len(key_prefix) == 0) {
        if (*saw_catch_all) {
            message_reset(); append("storage.rules["); append_uint(i); append("] is a duplicate catch-all rule");
            add_warning();
        }
        *saw_catch_all = 1;
        if ((sf_i64)i < count - 1) {
            message_reset(); append("storage.rules["); append_uint(i);
            append("] has an empty key_prefix and will shadow all later storage rules"); add_warning();
        }
    }
    if (key_prefix >= 0) sf_drop(key_prefix);

    if (require_auth_is(rule, 0) &&
        (operations_include(rule, "write") || operations_include(rule, "delete"))) {
        message_reset(); append("storage.rules["); append_uint(i);
        append("] allows unauthenticated write/delete access"); add_warning();
    }

    sf_drop(rule);
}

static void validate_storage(sf_handle parsed) {
    sf_handle storage = sf_json_get(parsed, "storage");
    if (storage < 0) return;
    if (!is_object(storage)) {
        message_reset(); append("storage must be an object"); add_error();
        sf_drop(storage);
        return;
    }

    sf_handle policy = sf_json_get(storage, "default_policy");
    if (policy >= 0) {
        int ok = sf_json_string_equals(storage, "default_policy", "deny") == 1 ||
                 sf_json_string_equals(storage, "default_policy", "allow") == 1;
        if (!ok) { message_reset(); append("storage.default_policy must be \"deny\" or \"allow\""); add_error(); }
        sf_drop(policy);
    }

    sf_handle rules = sf_json_get(storage, "rules");
    if (rules >= 0) {
        if (!is_array(rules)) {
            message_reset(); append("storage.rules must be an array"); add_error();
        } else {
            int saw_catch_all = 0;
            sf_i64 count = sf_bytes_len(rules);
            for (sf_i64 i = 0; i < count; ++i) validate_rule(rules, (sf_u64)i, count, &saw_catch_all);
        }
        sf_drop(rules);
    }
    sf_drop(storage);
}

static void validate_llm(sf_handle parsed) {
    sf_handle llm = sf_json_get(parsed, "llm");
    if (llm < 0) return;
    if (!is_object(llm)) {
        message_reset(); append("llm must be an object"); add_error();
        sf_drop(llm);
        return;
    }
    sf_handle enabled = sf_json_get(llm, "enabled");
    if (enabled >= 0 && !is_bool(enabled)) { message_reset(); append("llm.enabled must be a boolean"); add_error(); }
    sf_handle require_auth = sf_json_get(llm, "require_auth");
    if (require_auth >= 0 && !is_bool(require_auth)) {
        message_reset(); append("llm.require_auth must be a boolean"); add_error();
    }
    sf_handle rpm = sf_json_get(llm, "rate_limit_rpm");
    if (rpm >= 0 && !is_non_negative_integer(rpm)) {
        message_reset(); append("llm.rate_limit_rpm must be a non-negative integer"); add_error();
    }
    if (rpm >= 0) sf_drop(rpm);
    sf_handle max_tokens = sf_json_get(llm, "max_tokens");
    if (max_tokens >= 0 && !is_non_negative_integer(max_tokens)) {
        message_reset(); append("llm.max_tokens must be a non-negative integer"); add_error();
    }
    if (max_tokens >= 0) sf_drop(max_tokens);

    if (is_bool(enabled) && sf_json_bool(enabled) == 1 && is_bool(require_auth) && sf_json_bool(require_auth) == 0) {
        message_reset(); append("llm.enabled is true while llm.require_auth is false"); add_warning();
    }
    if (enabled >= 0) sf_drop(enabled);
    if (require_auth >= 0) sf_drop(require_auth);
    sf_drop(llm);
}

static int bearer_tokens_empty(sf_handle parsed) {
    sf_handle auth = sf_json_get(parsed, "auth");
    int empty = 1;
    if (is_object(auth)) {
        sf_handle tokens = sf_json_get(auth, "bearer_tokens");
        if (is_array(tokens) && sf_bytes_len(tokens) > 0) empty = 0;
        if (tokens >= 0) sf_drop(tokens);
    }
    if (auth >= 0) sf_drop(auth);
    return empty;
}

static int any_rule_requires_auth(sf_handle parsed) {
    sf_handle storage = sf_json_get(parsed, "storage");
    int found = 0;
    if (is_object(storage)) {
        sf_handle rules = sf_json_get(storage, "rules");
        if (is_array(rules)) {
            sf_i64 count = sf_bytes_len(rules);
            for (sf_i64 i = 0; i < count && !found; ++i) {
                sf_handle rule = sf_json_at(rules, (sf_u64)i);
                if (is_object(rule) && require_auth_is(rule, 1)) found = 1;
                if (rule >= 0) sf_drop(rule);
            }
        }
        if (rules >= 0) sf_drop(rules);
    }
    if (storage >= 0) sf_drop(storage);
    return found;
}

static int llm_enabled_and_requires_auth(sf_handle parsed) {
    sf_handle llm = sf_json_get(parsed, "llm");
    int result = 0;
    if (is_object(llm)) {
        sf_handle enabled = sf_json_get(llm, "enabled");
        sf_handle require_auth = sf_json_get(llm, "require_auth");
        result = is_bool(enabled) && sf_json_bool(enabled) == 1 &&
                 is_bool(require_auth) && sf_json_bool(require_auth) == 1;
        if (enabled >= 0) sf_drop(enabled);
        if (require_auth >= 0) sf_drop(require_auth);
    }
    if (llm >= 0) sf_drop(llm);
    return result;
}

/* ---- result assembly ------------------------------------------------------ */

static void set_flag(sf_handle object, const char *key, int value) {
    sf_handle flag = sf_json_boolean(value ? 1u : 0u);
    sf_json_set(object, key, flag);
    sf_drop(flag);
}

static void set_text(sf_handle object, const char *key, const char *text, sf_u64 len) {
    sf_handle value = len > 0 ? sf_json_string_raw(text, len) : sf_json_null();
    sf_json_set(object, key, value);
    sf_drop(value);
}

/* Builds the result and stores it; returns the exit code. */
static sf_i64 finish(sf_handle result, sf_handle api_json, int present, int valid_json) {
    set_flag(api_json, "present", present);
    set_flag(api_json, "valid_json", valid_json);
    set_flag(api_json, "schema_valid", present && valid_json && error_count == 0);
    set_flag(result, "ok", error_count == 0);
    sf_json_set(result, "errors", errors);
    sf_json_set(result, "warnings", warnings);
    sf_handle checks = sf_json_object();
    sf_json_set(checks, "api_json", api_json);
    sf_json_set(result, "checks", checks);
    sf_drop(checks);

    sf_handle args = sf_json_object();
    sf_json_set(args, "value", result);
    sf_handle stored = sf_host_call("script.result", args, 5000);
    sf_drop(args);
    if (stored < 0) return stored;
    sf_drop(stored);
    return 0;
}

SF_MAIN sf_i64 main(void) {
    char *site_name = site_name_buf;
    char *website_root = website_root_buf;
    char *api_path = api_path_buf;
    char *require = require_buf;
    char *tool_error = tool_error_buf;
    char *content = content_buf;

    errors = sf_json_array();
    warnings = sf_json_array();
    error_count = 0;

    sf_handle config = sf_config();
    sf_handle env = config >= 0 ? sf_json_get(config, "env") : -1;
    sf_i64 site_len = read_env(env, "SITE_NAME", site_name, TEXT_CAP);
    sf_i64 root_len = read_env(env, "WEBSITE_ROOT", website_root, TEXT_CAP);
    sf_i64 path_len = read_env(env, "API_JSON_PATH", api_path, TEXT_CAP);
    sf_i64 require_len = read_env(env, "REQUIRE_API_JSON", require, sizeof(require_buf));
    if (env >= 0) sf_drop(env);
    if (config >= 0) sf_drop(config);

    /* website_root defaults to /.salix/websites/<SITE_NAME>. */
    if (root_len == 0 && site_len > 0) {
        message_reset(); append("/.salix/websites/"); append(site_name);
        if (message_len + 1 < TEXT_CAP) {
            memcpy(website_root, message_buf, message_len);
            root_len = (sf_i64)message_len;
        }
    }
    /* api_json_path defaults to <website_root>/_api.json. */
    if (path_len == 0) {
        message_reset();
        if (root_len > 0) { append(website_root); append("/_api.json"); }
        else append("/.salix/websites/<site-name>/_api.json");
        memcpy(api_path, message_buf, message_len);
        path_len = (sf_i64)message_len;
    }
    /* site_name is NUL-free text: keep buffers terminated for append(). */
    if (site_len < TEXT_CAP) site_name[site_len] = 0;
    if (root_len < TEXT_CAP) website_root[root_len] = 0;
    if (path_len < TEXT_CAP) api_path[path_len] = 0;
    int require_api_json = require_len == 4 && memcmp(require, "true", 4) == 0;

    sf_handle result = sf_json_object();
    set_text(result, "site_name", site_name, (sf_u64)site_len);
    set_text(result, "website_root", website_root, (sf_u64)root_len);
    sf_handle api_json = sf_json_object();
    set_text(api_json, "path", api_path, (sf_u64)path_len);

    /* Read the file through the canonical tool. */
    sf_handle call = sf_json_object();
    sf_handle tool = sf_json_string("fs.read_file");
    sf_json_set(call, "tool", tool);
    sf_drop(tool);
    sf_handle args = sf_json_object();
    sf_handle path_value = sf_json_string_raw(api_path, (sf_u64)path_len);
    sf_json_set(args, "path", path_value);
    sf_drop(path_value);
    sf_json_set(call, "args", args);
    sf_drop(args);
    sf_handle reply = sf_host_call("salix.call", call, 20000);
    sf_drop(call);
    if (reply < 0) return reply;

    sf_handle ok = sf_json_get(reply, "ok");
    int read_ok = sf_json_bool(ok) == 1;
    if (ok >= 0) sf_drop(ok);

    if (!read_ok) {
        sf_handle error = sf_json_get(reply, "error");
        sf_i64 error_len = error >= 0 ? sf_json_read_string(error, tool_error, TOOL_ERROR_CAP) : 0;
        if (error >= 0) sf_drop(error);
        sf_drop(reply);
        if (error_len < 0 || error_len > TOOL_ERROR_CAP) error_len = 0;
        int not_found = text_contains(tool_error, (sf_u64)error_len, "file not found") ||
                        text_contains(tool_error, (sf_u64)error_len, "no such file");
        if (!not_found) {
            message_reset(); append("Unable to read "); append(api_path); append(": ");
            if (error_len > 0) {
                if (message_len + (sf_u64)error_len >= TEXT_CAP) error_len = (sf_i64)(TEXT_CAP - 1 - message_len);
                memcpy(message_buf + message_len, tool_error, (sf_u64)error_len);
                message_len += (sf_u64)error_len;
            }
            add_error();
            return finish(result, api_json, 0, 0);
        }
        if (require_api_json) { message_reset(); append("Missing "); append(api_path); add_error(); }
        else { message_reset(); append("No "); append(api_path); append(" found. Site APIs are disabled by default."); add_warning(); }
        return finish(result, api_json, 0, 0);
    }

    /* value is the decoded tool content. A file that is itself JSON arrives
     * already decoded (an object without "content"); any other file arrives
     * as {"content": text}. */
    sf_handle truncated = sf_json_get(reply, "truncated");
    int was_truncated = truncated >= 0 && sf_json_bool(truncated) == 1;
    if (truncated >= 0) sf_drop(truncated);
    sf_handle value = sf_json_get(reply, "value");
    sf_handle content_value = value >= 0 ? sf_json_get(value, "content") : -1;
    sf_drop(reply);

    if (was_truncated) {
        if (content_value >= 0) sf_drop(content_value);
        if (value >= 0) sf_drop(value);
        message_reset(); append(api_path); append(" is larger than 16 KiB and cannot be validated by this script");
        add_error();
        return finish(result, api_json, 1, 0);
    }

    sf_handle parsed;
    if (content_value < 0 && is_object(value)) {
        parsed = value;
    } else {
        sf_i64 content_len = content_value >= 0 ? sf_json_read_string(content_value, content, CONTENT_CAP) : -1;
        if (content_value >= 0) sf_drop(content_value);
        if (value >= 0) sf_drop(value);
        if (content_len < 0 || content_len > CONTENT_CAP) {
            message_reset(); append("Invalid JSON in "); append(api_path); add_error();
            return finish(result, api_json, 1, 0);
        }
        parsed = sf_json_parse(content, (sf_u64)content_len);
        if (parsed < 0) {
            message_reset(); append("Invalid JSON in "); append(api_path); add_error();
            return finish(result, api_json, 1, 0);
        }
    }
    if (!is_object(parsed)) {
        message_reset(); append("_api.json top level must be a JSON object"); add_error();
        sf_drop(parsed);
        return finish(result, api_json, 1, 1);
    }

    validate_auth(parsed);
    validate_storage(parsed);
    validate_llm(parsed);

    if (error_count == 0 && any_rule_requires_auth(parsed) && bearer_tokens_empty(parsed)) {
        message_reset();
        append("Authenticated storage rules are configured, but auth.bearer_tokens is empty");
        add_warning();
    }
    if (error_count == 0 && llm_enabled_and_requires_auth(parsed) && bearer_tokens_empty(parsed)) {
        message_reset(); append("llm.require_auth is true, but auth.bearer_tokens is empty"); add_warning();
    }
    sf_drop(parsed);
    return finish(result, api_json, 1, 1);
}
