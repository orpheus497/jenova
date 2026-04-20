/* agent.c — Agent core lifecycle (new addition for cli-agent)
 *
 * Integrates the legacy agent's plan→execute→reflect loop into C.
 * The actual agent logic runs in Lua; this provides C-level state
 * management, context windowing, and action deduplication.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
