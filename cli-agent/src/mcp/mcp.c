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

/* Extract the numeric or null `id` field from a JSON-RPC message using the
 * proper jenova_json_get() helper so that keys in nested objects, string
 * values containing "id", and reordered fields are handled correctly.
 * Returns the id value as a long, or 0 if the id is null / absent / non-
 * numeric.  The caller is responsible for freeing *id_str_out if non-NULL. */
static long _extract_id(const char *message, char **id_str_out) {
    if (id_str_out) *id_str_out = NULL;
    if (!message) return 0;

    char *id_val = jenova_json_get(message, "id");
    if (!id_val) return 0;

    if (strcmp(id_val, "null") == 0) {
        jenova_json_free(id_val);
        return 0;
    }

    long id = strtol(id_val, NULL, 10);
    if (id_str_out) {
        *id_str_out = id_val;
    } else {
        jenova_json_free(id_val);
    }
    return id;
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

    if (strstr(message, "\"method\"")) {
        char *method_val = jenova_json_get(message, "method");
        if (method_val) { jenova_json_free(method_val); }
        char *id_val = jenova_json_get(message, "id");
        int has_id = (id_val != NULL);
        if (id_val) jenova_json_free(id_val);

        if (has_id) {
            return strdup("{\"type\":\"request\"}");
        }
        return strdup("{\"type\":\"notification\"}");
    }
    if (strstr(message, "\"result\"") || strstr(message, "\"error\"")) {
        return strdup("{\"type\":\"response\"}");
    }
    return strdup("{\"type\":\"unknown\"}");
}

char *jenova_mcp_handle_message(const char *message) {
    if (!message) return NULL;

    char *method_val = jenova_json_get(message, "method");
    int is_ping = method_val && strcmp(method_val, "ping") == 0;
    if (method_val) jenova_json_free(method_val);

    long id = _extract_id(message, NULL);

    if (is_ping) {
        char buf[128];
        snprintf(buf, sizeof(buf), "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"result\":{}}", id);
        return strdup(buf);
    }

    char buf[256];
    if (id != 0) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%ld,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", id);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    }
    return strdup(buf);
}
