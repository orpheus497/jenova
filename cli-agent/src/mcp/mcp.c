/* mcp.c — Model Context Protocol (replaces Rust jenova-mcp)
 *
 * JSON-RPC 2.0 message building and parsing for MCP communication.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "jenova.h"

/* Atomic request-ID counter: safe for concurrent use across connections. */
static atomic_ulong g_mcp_next_id = 1;

/* Represents the result of extracting the JSON-RPC `id` field.  `has_id` is
 * 1 when the field is present and non-null; in that case `value` holds the
 * numeric id.  This avoids conflating "id absent" with "id == 0". */
typedef struct { int has_id; long value; } _id_result_t;

/* Extract the numeric or null `id` field from a JSON-RPC message using
 * jenova_json_get() so nested objects, escaped quotes, and reordered fields
 * are handled correctly. */
static _id_result_t _extract_id(const char *message) {
    _id_result_t r = {0, 0};
    if (!message) return r;

    char *id_val = jenova_json_get(message, "id");
    if (!id_val) return r;

    if (strcmp(id_val, "null") != 0) {
        r.has_id = 1;
        r.value  = strtol(id_val, NULL, 10);
    }
    jenova_json_free(id_val);
    return r;
}

char *jenova_mcp_build_init_request(void) {
    char buf[512];
    unsigned long id = atomic_fetch_add(&g_mcp_next_id, 1UL);
    snprintf(buf, sizeof(buf),
        "{\"jsonrpc\":\"2.0\",\"id\":%lu,\"method\":\"initialize\","
        "\"params\":{\"protocolVersion\":\"2024-11-05\","
        "\"capabilities\":{\"roots\":{\"listChanged\":true}},"
        "\"clientInfo\":{\"name\":\"cli-agent\",\"version\":\"0.2.0\"}}}",
        id);
    return strdup(buf);
}

char *jenova_mcp_parse_message(const char *message) {
    if (!message) return NULL;

    /* Use jenova_json_get() for top-level field presence checks so that
     * substrings appearing only inside string values do not cause false
     * positives (e.g. {"note":"has a method field"} must not be a request). */
    char *method_val = jenova_json_get(message, "method");
    if (method_val) {
        jenova_json_free(method_val);
        _id_result_t id_r = _extract_id(message);
        return strdup(id_r.has_id ? "{\"type\":\"request\"}" : "{\"type\":\"notification\"}");
    }

    char *result_val = jenova_json_get(message, "result");
    char *error_val  = jenova_json_get(message, "error");
    int is_response  = (result_val != NULL || error_val != NULL);
    if (result_val) jenova_json_free(result_val);
    if (error_val)  jenova_json_free(error_val);
    if (is_response) return strdup("{\"type\":\"response\"}");

    return strdup("{\"type\":\"unknown\"}");
}

char *jenova_mcp_handle_message(const char *message) {
    if (!message) return NULL;

    char *method_val = jenova_json_get(message, "method");
    int is_ping = method_val && strcmp(method_val, "ping") == 0;
    if (method_val) jenova_json_free(method_val);

    _id_result_t id_r = _extract_id(message);

    char buf[256];
    if (is_ping) {
        if (id_r.has_id) {
            snprintf(buf, sizeof(buf),
                "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"result\":{}}", id_r.value);
        } else {
            snprintf(buf, sizeof(buf),
                "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}");
        }
        return strdup(buf);
    }

    if (id_r.has_id) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
            id_r.value);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    }
    return strdup(buf);
}
