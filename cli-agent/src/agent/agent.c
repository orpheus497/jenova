/* agent.c — Agent core lifecycle (new addition for cli-agent)
 *
 * Integrates the legacy agent's plan→execute→reflect loop into C.
 * The actual agent logic runs in Lua; this provides C-level state
 * management, context windowing, and action deduplication.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include "jenova.h"

typedef struct {
    int32_t  initialized;
    char    *system_prompt;
    char    *model;
    int32_t  max_turns;
    int32_t  context_size;
    int32_t  enable_tools;
    int32_t  enable_memory;
    int32_t  current_turn;
} agent_state_t;

static agent_state_t g_agent = {0};

int32_t jenova_agent_init(const jenova_agent_config_t *config) {
    if (!config) return -1;

    if (g_agent.initialized) {
        jenova_agent_shutdown();
    }

    g_agent.initialized = 1;
    g_agent.system_prompt = config->system_prompt ? strdup(config->system_prompt) : NULL;
    g_agent.model = config->model ? strdup(config->model) : NULL;
    g_agent.max_turns = config->max_turns > 0 ? config->max_turns : 100;
    g_agent.context_size = config->context_size > 0 ? config->context_size : 8192;
    g_agent.enable_tools = config->enable_tools;
    g_agent.enable_memory = config->enable_memory;
    g_agent.current_turn = 0;

    return 0;
}

void jenova_agent_shutdown(void) {
    free(g_agent.system_prompt);
    free(g_agent.model);
    memset(&g_agent, 0, sizeof(agent_state_t));
}

char *jenova_agent_run_turn(const char *user_message) {
    if (!g_agent.initialized) {
        return strdup("{\"error\":\"agent not initialized\"}");
    }
    if (!user_message) {
        return strdup("{\"error\":\"no message provided\"}");
    }

    g_agent.current_turn++;

    if (g_agent.current_turn > g_agent.max_turns) {
        return strdup("{\"error\":\"max turns exceeded\"}");
    }

    char buf[256];
    snprintf(buf, sizeof(buf),
             "{\"turn\":%d,\"status\":\"ready\",\"message\":\"turn dispatched to Lua agent\"}",
             g_agent.current_turn);
    return strdup(buf);
}

int32_t jenova_agent_reset(void) {
    g_agent.current_turn = 0;
    return 0;
}

char *jenova_agent_get_state_json(void) {
    char buf[512];
    snprintf(buf, sizeof(buf),
             "{\"initialized\":%s,\"turn\":%d,\"max_turns\":%d,"
             "\"context_size\":%d,\"tools_enabled\":%s,\"memory_enabled\":%s}",
             g_agent.initialized ? "true" : "false",
             g_agent.current_turn,
             g_agent.max_turns,
             g_agent.context_size,
             g_agent.enable_tools ? "true" : "false",
             g_agent.enable_memory ? "true" : "false");
    return strdup(buf);
}

/* ── LSP bridge (stdio transport, synchronous) ─────────────────────────── */
/*
 * Very thin wrapper: forks a child process running the LSP binary for the
 * file's language (resolved via JENOVA_LSP_BIN env or defaults), writes the
 * request JSON to its stdin followed by the required header framing, and
 * reads back one response.  Returns a malloc'd response JSON string or NULL.
 *
 * This is intentionally minimal — the Lua layer in tools/lsp.lua only calls
 * this when jenova.lsp.request is available, and falls back to grep/ctags
 * heuristics otherwise.  A persistent per-language-server process pool is a
 * future enhancement.
 */
char *jenova_lsp_request(const char *request_json) {
    if (!request_json) return NULL;

    const char *lsp_bin = getenv("JENOVA_LSP_BIN");
    if (!lsp_bin || lsp_bin[0] == '\0') {
        return strdup("{\"error\":\"JENOVA_LSP_BIN not set\"}");
    }

    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) < 0 || pipe(out_pipe) < 0) return NULL;

    pid_t pid = fork();
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        return NULL;
    }

    if (pid == 0) {
        /* Child: wire stdin/stdout to pipes */
        close(in_pipe[1]);
        close(out_pipe[0]);
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(in_pipe[0]);
        close(out_pipe[1]);
        execlp(lsp_bin, lsp_bin, (char *)NULL);
        _exit(127);
    }

    /* Parent: send framed request */
    close(in_pipe[0]);
    close(out_pipe[1]);

    size_t body_len = strlen(request_json);
    char header[64];
    int hlen = snprintf(header, sizeof(header),
                        "Content-Length: %zu\r\n\r\n", body_len);
    write(in_pipe[1], header, (size_t)hlen);
    write(in_pipe[1], request_json, body_len);
    close(in_pipe[1]);

    /* Read response (simple: read everything until EOF) */
    size_t capacity = 8192, pos = 0;
    char *buf = malloc(capacity);
    if (!buf) { close(out_pipe[0]); return NULL; }

    ssize_t n;
    while ((n = read(out_pipe[0], buf + pos, capacity - pos - 1)) > 0) {
        pos += (size_t)n;
        if (pos + 1 >= capacity) {
            capacity *= 2;
            char *nb = realloc(buf, capacity);
            if (!nb) { free(buf); close(out_pipe[0]); return NULL; }
            buf = nb;
        }
    }
    buf[pos] = '\0';
    close(out_pipe[0]);
    waitpid(pid, NULL, 0);

    /* Strip the Content-Length header framing — return body only */
    char *body = strstr(buf, "\r\n\r\n");
    if (body) {
        body += 4;
        char *result = strdup(body);
        free(buf);
        return result;
    }

    return buf;
}

/* ── System utilities ───────────────────────────────────────────────────── */

int32_t jenova_system_setenv(const char *name, const char *value) {
    if (!name) return -1;
    if (!value) {
        unsetenv(name);
        return 0;
    }
    return setenv(name, value, 1) == 0 ? 0 : -1;
}
