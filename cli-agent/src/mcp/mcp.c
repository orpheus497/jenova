/* mcp.c — Model Context Protocol (replaces Rust jenova-mcp)
 *
 * JSON-RPC 2.0 message building and parsing for MCP communication.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "jenova.h"

static unsigned long g_mcp_next_id = 1;

char *jenova_mcp_build_init_request(void) {
    char buf[512];
    unsigned long id = g_mcp_next_id++;
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
        if (strstr(message, "\"id\"")) {
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

    if (strstr(message, "\"ping\"")) {
        const char *id_str = strstr(message, "\"id\"");
        int id = 1;
        if (id_str) {
            id_str = strchr(id_str + 4, ':');
            if (id_str) id = atoi(id_str + 1);
        }
        char buf[128];
        snprintf(buf, sizeof(buf), "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":{}}", id);
        return strdup(buf);
    }

    const char *id_str = strstr(message, "\"id\"");
    int id_found = 0;
    int id_val = 0;
    if (id_str) {
        id_str = strchr(id_str + 4, ':');
        if (id_str) { id_val = atoi(id_str + 1); id_found = 1; }
    }
    char buf[256];
    if (id_found) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%d,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", id_val);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    }
    return strdup(buf);
}
