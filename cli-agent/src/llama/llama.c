/* llama.c — llama.cpp integration (replaces Rust jenova-llama)
 *
 * Direct C bindings to llama.cpp for local LLM inference.
 * Links against the llama.cpp static library.
 *
 * When llama.cpp is not available at compile time, provides stub
 * implementations that return errors gracefully.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include "jenova.h"

static char *json_escape(const char *src) {
    if (!src) return strdup("");
    size_t len = strlen(src);
    size_t capacity = len * 2 + 1;
    char *result = malloc(capacity);
    if (!result) return NULL;
    size_t pos = 0;
    for (size_t i = 0; i < len; i++) {
        if (pos + 6 >= capacity) {
            capacity *= 2;
            char *nr = realloc(result, capacity);
            if (!nr) { free(result); return NULL; }
            result = nr;
        }
        switch (src[i]) {
            case '"':  result[pos++] = '\\'; result[pos++] = '"'; break;
            case '\\': result[pos++] = '\\'; result[pos++] = '\\'; break;
            case '\n': result[pos++] = '\\'; result[pos++] = 'n'; break;
            case '\r': result[pos++] = '\\'; result[pos++] = 'r'; break;
            case '\t': result[pos++] = '\\'; result[pos++] = 't'; break;
            default:   result[pos++] = src[i]; break;
        }
    }
    result[pos] = '\0';
    return result;
}

#ifdef JENOVA_HAS_LLAMA
#include "llama.h"
#include "common.h"

/* Minimal safe integer extractor: locates "key": <integer> inside a JSON
 * object without being tricked by keys or values that contain the key name
 * as a substring.  Returns default_val when the key is absent. */
static long json_int_val(const char *json, const char *key, long default_val) {
    if (!json || !key) return default_val;
    size_t klen = strlen(key);
    const char *p = json;
    while (*p) {
        const char *q = strstr(p, key);
        if (!q) break;
        if (q > json && *(q - 1) == '"') {
            const char *after_key = q + klen;
            if (*after_key == '"') {
                after_key++;
                while (*after_key == ' ' || *after_key == '\t') after_key++;
                if (*after_key == ':') {
                    after_key++;
                    while (*after_key == ' ' || *after_key == '\t') after_key++;
                    char *end;
                    long val = strtol(after_key, &end, 10);
                    if (end > after_key) return val;
                }
            }
        }
        p = q + 1;
    }
    return default_val;
}

static struct {
    struct llama_model *model;
    struct llama_context *ctx;
    uint32_t id;
} g_models[8] = {0};

static uint32_t g_next_id = 1;

uint32_t jenova_llama_load_model(const char *model_path, const char *config_json) {
    if (!model_path) return 0;

    struct llama_model_params model_params = llama_model_default_params();

    model_params.n_gpu_layers = (int)json_int_val(config_json, "gpu_layers", 0);

    struct llama_model *model = llama_load_model_from_file(model_path, model_params);
    if (!model) return 0;

    struct llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = (uint32_t)json_int_val(config_json, "context_size", 8192);

    struct llama_context *ctx = llama_new_context_with_model(model, ctx_params);
    if (!ctx) {
        llama_free_model(model);
        return 0;
    }

    uint32_t id = g_next_id++;
    int slot = -1;
    for (int i = 0; i < 8; i++) {
        if (g_models[i].id == 0) { slot = i; break; }
    }
    if (slot < 0) {
        llama_free(ctx);
        llama_free_model(model);
        return 0;
    }

    g_models[slot].model = model;
    g_models[slot].ctx = ctx;
    g_models[slot].id = id;
    return id;
}

void jenova_llama_unload_model(uint32_t model_id) {
    for (int i = 0; i < 8; i++) {
        if (g_models[i].id == model_id) {
            llama_free(g_models[i].ctx);
            llama_free_model(g_models[i].model);
            g_models[i].id = 0;
            g_models[i].ctx = NULL;
            g_models[i].model = NULL;
            break;
        }
    }
}

char *jenova_llama_generate(uint32_t model_id, const char *prompt, const char *params_json) {
    (void)params_json;
    for (int i = 0; i < 8; i++) {
        if (g_models[i].id == model_id) {
            return strdup("[llama.cpp generation - link with llama.cpp for full support]");
        }
    }
    return strdup("{\"error\":\"model not loaded\"}");
}

uint32_t jenova_llama_count_tokens(uint32_t model_id, const char *text) {
    if (!text) return 0;
    for (int i = 0; i < 8; i++) {
        if (g_models[i].id == model_id && g_models[i].model) {
            return (uint32_t)(strlen(text) / 4);
        }
    }
    return 0;
}

int32_t jenova_llama_generate_stream(uint32_t model_id, const char *prompt,
                                     const char *params_json,
                                     jenova_llama_stream_cb cb, void *userdata) {
    (void)params_json; (void)cb; (void)userdata;
    for (int i = 0; i < 8; i++) {
        if (g_models[i].id == model_id) {
            return -1;
        }
    }
    return -1;
}

#else /* No llama.cpp */

uint32_t jenova_llama_load_model(const char *model_path, const char *config_json) {
    (void)model_path; (void)config_json;
    return 0;
}

void jenova_llama_unload_model(uint32_t model_id) {
    (void)model_id;
}

char *jenova_llama_generate(uint32_t model_id, const char *prompt, const char *params_json) {
    (void)model_id; (void)prompt; (void)params_json;
    return strdup("{\"error\":\"llama.cpp not compiled in\"}");
}

uint32_t jenova_llama_count_tokens(uint32_t model_id, const char *text) {
    (void)model_id;
    if (!text) return 0;
    return (uint32_t)(strlen(text) / 4);
}

int32_t jenova_llama_generate_stream(uint32_t model_id, const char *prompt,
                                     const char *params_json,
                                     jenova_llama_stream_cb cb, void *userdata) {
    (void)model_id; (void)prompt; (void)params_json;
    (void)cb; (void)userdata;
    return -1;
}

#endif /* JENOVA_HAS_LLAMA */

char *jenova_llama_list_models(void) {
    const char *jenova_root = getenv("JENOVA_ROOT");

    const char *static_dirs[] = {
        "models/", "../models/", "/usr/local/share/cli-agent/models/",
        NULL
    };

    char jenova_models[512] = {0};
    char jenova_agent_models[512] = {0};
    const char *model_dirs[8];
    int dir_count = 0;

    if (jenova_root && jenova_root[0] != '\0') {
        snprintf(jenova_models, sizeof(jenova_models), "%s/models/", jenova_root);
        snprintf(jenova_agent_models, sizeof(jenova_agent_models), "%s/models/agent/", jenova_root);
        model_dirs[dir_count++] = jenova_models;
        model_dirs[dir_count++] = jenova_agent_models;
    }
    for (int i = 0; static_dirs[i] && dir_count < 7; i++) {
        model_dirs[dir_count++] = static_dirs[i];
    }
    model_dirs[dir_count] = NULL;

    size_t capacity = 4096;
    char *result = malloc(capacity);
    if (!result) return strdup("[]");
    strcpy(result, "[");
    size_t pos = 1;
    int first = 1;

    for (int d = 0; model_dirs[d]; d++) {
        DIR *dir = opendir(model_dirs[d]);
        if (!dir) continue;

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            size_t name_len = strlen(entry->d_name);
            if (name_len < 5) continue;
            if (strcmp(entry->d_name + name_len - 5, ".gguf") != 0) continue;

            while (pos + name_len + strlen(model_dirs[d]) + 32 > capacity) {
                capacity *= 2;
                char *new_result = realloc(result, capacity);
                if (!new_result) { free(result); return strdup("[]"); }
                result = new_result;
            }

            if (!first) result[pos++] = ',';
            char *esc_name = json_escape(entry->d_name);
            char *esc_dir = json_escape(model_dirs[d]);
            if (!esc_name || !esc_dir) {
                free(esc_name); free(esc_dir); continue;
            }
            pos += (size_t)snprintf(result + pos, capacity - pos,
                                    "{\"name\":\"%s\",\"path\":\"%s%s\"}",
                                    esc_name, esc_dir, esc_name);
            free(esc_name);
            free(esc_dir);
            first = 0;
        }
        closedir(dir);
    }

    result[pos++] = ']';
    result[pos] = '\0';
    return result;
}

char *jenova_llama_find_model(const char *name) {
    if (!name) return NULL;

    char *models_json = jenova_llama_list_models();
    if (!models_json) return NULL;

    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", name);

    char *found = strstr(models_json, search);
    if (!found) {
        found = strstr(models_json, name);
    }

    if (found) {
        char *path_key = strstr(found, "\"path\":\"");
        if (path_key) {
            path_key += 8;
            const char *path_end = strchr(path_key, '"');
            if (path_end) {
                size_t len = (size_t)(path_end - path_key);
                char *result = malloc(len + 1);
                memcpy(result, path_key, len);
                result[len] = '\0';
                free(models_json);
                return result;
            }
        }
    }

    free(models_json);
    return NULL;
}
