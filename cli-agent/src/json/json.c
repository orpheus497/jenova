/* json.c — JSON utilities (replaces Rust jenova-json)
 *
 * Minimal JSON validation, pretty-printing, and path extraction.
 * Uses a lightweight approach without external dependencies.
 * For full JSON parsing, the Lua layer uses its own json_fallback module.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "jenova.h"

char *jenova_json_parse(const char *json_str) {
    if (!json_str) return NULL;
    return strdup(json_str);
}

char *jenova_json_stringify(const char *json_str) {
    if (!json_str) return NULL;

    size_t in_len = strlen(json_str);
    size_t capacity = in_len * 2 + 128;
    char *out = malloc(capacity);
    if (!out) return NULL;
    size_t pos = 0;
    int indent = 0;
    int in_string = 0;

    for (size_t i = 0; i < in_len; i++) {
        char c = json_str[i];

        /* Worst case per iteration: newline + indent spaces + 2 chars + NUL.
         * Grow until we have enough headroom before touching `out`. */
        size_t needed = (size_t)indent + 4;
        while (pos + needed + 1 > capacity) {
            capacity *= 2;
            char *new_out = realloc(out, capacity);
            if (!new_out) { free(out); return NULL; }
            out = new_out;
        }

        if (in_string) {
            out[pos++] = c;
            if (c == '"') {
                int backslashes = 0;
                for (int k = (int)i - 1; k >= 0 && json_str[k] == '\\'; k--) {
                    backslashes++;
                }
                if (backslashes % 2 == 0) {
                    in_string = 0;
                }
            }
            continue;
        }

        switch (c) {
            case '"':
                in_string = 1;
                out[pos++] = c;
                break;
            case '{':
            case '[':
                out[pos++] = c;
                out[pos++] = '\n';
                indent += 2;
                for (int j = 0; j < indent; j++) out[pos++] = ' ';
                break;
            case '}':
            case ']':
                out[pos++] = '\n';
                indent -= 2;
                if (indent < 0) indent = 0;
                for (int j = 0; j < indent; j++) out[pos++] = ' ';
                out[pos++] = c;
                break;
            case ',':
                out[pos++] = c;
                out[pos++] = '\n';
                for (int j = 0; j < indent; j++) out[pos++] = ' ';
                break;
            case ':':
                out[pos++] = c;
                out[pos++] = ' ';
                break;
            case ' ':
            case '\t':
            case '\n':
            case '\r':
                break;
            default:
                out[pos++] = c;
                break;
        }
    }
    out[pos] = '\0';
    return out;
}

static const char *json_skip_ws(const char *p) {
    while (*p && isspace((unsigned char)*p)) p++;
    return p;
}

static const char *json_find_string_end(const char *p) {
    while (*p) {
        if (*p == '\\') {
            p++;
            if (!*p) return NULL;
        } else if (*p == '"') {
            return p;
        }
        p++;
    }
    return NULL;
}

static int json_key_matches(const char *start, const char *end, const char *key) {
    size_t len = (size_t)(end - start);
    return strlen(key) == len && strncmp(start, key, len) == 0;
}

/* jenova_json_get — extract a top-level string or scalar value from a flat
 * JSON object.  Only keys at depth 1 (the outermost object) are examined, so
 * identically-named keys inside nested objects or arrays are never matched.
 * The function does not handle Unicode escapes in key names; callers must use
 * plain ASCII keys.  For deeply nested or complex JSON use the Lua-side
 * json_fallback module instead. */
char *jenova_json_get(const char *json_str, const char *path) {
    if (!json_str || !path) return NULL;

    const char *p = json_skip_ws(json_str);
    if (*p != '{') return NULL;
    p++;

    int depth = 1;

    while (*p && depth >= 1) {
        p = json_skip_ws(p);
        if (!*p) break;

        if (*p == '{' || *p == '[') {
            depth++;
            p++;
            continue;
        }
        if (*p == '}' || *p == ']') {
            depth--;
            p++;
            continue;
        }

        /* Skip strings at depth > 1 so that structural characters inside
         * string values (e.g. "{" in "hello {world}") do not corrupt the
         * depth counter. */
        if (*p == '"' && depth > 1) {
            const char *end = json_find_string_end(p + 1);
            p = end ? end + 1 : p + 1;
            continue;
        }

        /* Only try to match keys at the top level of the outer object. */
        if (*p == '"' && depth == 1) {
            const char *key_start = p + 1;
            const char *key_end = json_find_string_end(key_start);
            if (!key_end) return NULL;

            const char *after_key = json_skip_ws(key_end + 1);
            if (*after_key == ':') {
                if (json_key_matches(key_start, key_end, path)) {
                    const char *value_start = json_skip_ws(after_key + 1);
                    if (!*value_start) return NULL;

                    if (*value_start == '"') {
                        const char *value_end = json_find_string_end(value_start + 1);
                        if (!value_end) return NULL;
                        size_t len = (size_t)(value_end - (value_start + 1));
                        char *result = malloc(len + 1);
                        if (!result) return NULL;
                        memcpy(result, value_start + 1, len);
                        result[len] = '\0';
                        return result;
                    } else {
                        const char *end = value_start;
                        while (*end && *end != ',' && *end != '}' && *end != ']') end++;
                        while (end > value_start && isspace((unsigned char)*(end - 1))) end--;
                        size_t len = (size_t)(end - value_start);
                        char *result = malloc(len + 1);
                        if (!result) return NULL;
                        memcpy(result, value_start, len);
                        result[len] = '\0';
                        return result;
                    }
                }
                /* Skip past the value (whatever type) so the depth tracking
                 * in the outer loop handles nested objects/arrays correctly. */
                p = after_key + 1;
                continue;
            }
            /* Bare string not followed by ':' — skip past it. */
            p = key_end + 1;
            continue;
        }

        p++;
    }
    return NULL;
}

void jenova_json_free(char *ptr) {
    free(ptr);
}
