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

/* Skip a complete JSON value starting at `p` (after whitespace has been
 * consumed) and return a pointer to the character immediately after it.
 * Correctly handles strings, objects, arrays, and scalars.
 * Returns NULL if the input is malformed. */
static const char *json_skip_value(const char *p) {
    p = json_skip_ws(p);
    if (!*p) return NULL;

    if (*p == '"') {
        const char *end = json_find_string_end(p + 1);
        return end ? end + 1 : NULL;
    }

    if (*p == '{' || *p == '[') {
        int d = 1;
        p++;
        while (*p && d > 0) {
            if (*p == '"') {
                /* Skip string contents so structural characters inside strings
                 * do not affect the depth counter. */
                const char *se = json_find_string_end(p + 1);
                if (!se) return NULL;
                p = se + 1;
                continue;
            }
            if (*p == '{' || *p == '[') d++;
            else if (*p == '}' || *p == ']') d--;
            p++;
        }
        return (d == 0) ? p : NULL;
    }

    /* Scalar: number, true, false, null — advance to the next delimiter. */
    while (*p && *p != ',' && *p != '}' && *p != ']') p++;
    return p;
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

    while (1) {
        p = json_skip_ws(p);
        if (!*p) break;
        /* End of object */
        if (*p == '}') break;
        /* Comma between key-value pairs */
        if (*p == ',') { p++; continue; }

        /* We expect a key string at this level of the outer object. */
        if (*p != '"') return NULL;

        const char *key_start = p + 1;
        const char *key_end   = json_find_string_end(key_start);
        if (!key_end) return NULL;

        const char *after_colon = json_skip_ws(key_end + 1);
        if (*after_colon != ':') return NULL;

        const char *value_start = json_skip_ws(after_colon + 1);
        if (!*value_start) return NULL;

        if (json_key_matches(key_start, key_end, path)) {
            /* Extract the value. */
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

        /* Key did not match: skip the entire value so structural characters
         * inside nested objects, arrays, or string values never corrupt the
         * parser state. */
        p = json_skip_value(value_start);
        if (!p) return NULL;
    }
    return NULL;
}

void jenova_json_free(char *ptr) {
    free(ptr);
}
