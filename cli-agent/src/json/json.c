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
    size_t pos = 0;
    int indent = 0;
    int in_string = 0;

    for (size_t i = 0; i < in_len; i++) {
        char c = json_str[i];

        if (pos + 64 > capacity) {
            capacity *= 2;
            out = realloc(out, capacity);
        }

        if (in_string) {
            out[pos++] = c;
            if (c == '"' && (i == 0 || json_str[i-1] != '\\')) {
                in_string = 0;
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

char *jenova_json_get(const char *json_str, const char *path) {
    if (!json_str || !path) return NULL;

    char key[256];
    snprintf(key, sizeof(key), "\"%s\"", path);

    const char *found = strstr(json_str, key);
    if (!found) return NULL;

    found += strlen(key);
    while (*found && (*found == ' ' || *found == ':')) found++;

    if (*found == '"') {
        found++;
        const char *end = strchr(found, '"');
        if (!end) return NULL;
        size_t len = (size_t)(end - found);
        char *result = malloc(len + 1);
        memcpy(result, found, len);
        result[len] = '\0';
        return result;
    }

    const char *end = found;
    while (*end && *end != ',' && *end != '}' && *end != ']' && *end != '\n') end++;
    size_t len = (size_t)(end - found);
    char *result = malloc(len + 1);
    memcpy(result, found, len);
    result[len] = '\0';
    return result;
}

void jenova_json_free(char *ptr) {
    free(ptr);
}
