/* auth.c — API key management (replaces Rust jenova-auth)
 *
 * Handles API key validation, resolution from environment/files,
 * storage in ~/.config/cli-agent/keys, and header building.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "jenova.h"

#define KEYS_DIR_REL "/.config/cli-agent/keys/"

static char *get_keys_dir(void) {
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    size_t len = strlen(home) + strlen(KEYS_DIR_REL) + 1;
    char *dir = malloc(len);
    snprintf(dir, len, "%s%s", home, KEYS_DIR_REL);
    return dir;
}

static char *get_key_path(const char *provider) {
    char *dir = get_keys_dir();
    size_t len = strlen(dir) + strlen(provider) + 1;
    char *path = malloc(len);
    snprintf(path, len, "%s%s", dir, provider);
    free(dir);
    return path;
}

int32_t jenova_auth_validate_key(const char *provider, const char *key) {
    if (!key || strlen(key) < 8) return 0;

    if (strcmp(provider, "anthropic") == 0) {
        return strncmp(key, "sk-ant-", 7) == 0;
    } else if (strcmp(provider, "openai") == 0) {
        return strncmp(key, "sk-", 3) == 0;
    } else if (strcmp(provider, "gemini") == 0) {
        return strncmp(key, "AI", 2) == 0;
    } else if (strcmp(provider, "openrouter") == 0) {
        return strncmp(key, "sk-or-", 6) == 0;
    }
    return strlen(key) >= 20;
}

char *jenova_auth_resolve_key(const char *provider) {
    char env_var[128];
    snprintf(env_var, sizeof(env_var), "%s_API_KEY", provider);
    for (char *p = env_var; *p; p++) {
        if (*p >= 'a' && *p <= 'z') *p -= 32;
        if (*p == '-') *p = '_';
    }

    const char *env_key = getenv(env_var);
    if (env_key && strlen(env_key) > 0) {
        return strdup(env_key);
    }

    char *path = get_key_path(provider);
    FILE *f = fopen(path, "r");
    free(path);
    if (!f) return NULL;

    char buf[512];
    if (fgets(buf, sizeof(buf), f)) {
        fclose(f);
        size_t len = strlen(buf);
        while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r')) {
            buf[--len] = '\0';
        }
        return strdup(buf);
    }
    fclose(f);
    return NULL;
}

int32_t jenova_auth_store_key(const char *provider, const char *key) {
    char *dir = get_keys_dir();
    mkdir(dir, 0700);
    free(dir);

    char *path = get_key_path(provider);
    FILE *f = fopen(path, "w");
    free(path);
    if (!f) return -1;

    fprintf(f, "%s\n", key);
    fclose(f);
    return 0;
}

int32_t jenova_auth_delete_key(const char *provider) {
    char *path = get_key_path(provider);
    int result = unlink(path);
    free(path);
    return result;
}

char *jenova_auth_build_headers(const char *provider, const char *key) {
    char buf[1024];

    if (strcmp(provider, "anthropic") == 0) {
        snprintf(buf, sizeof(buf),
                 "{\"x-api-key\":\"%s\",\"anthropic-version\":\"2023-06-01\"}", key);
    } else if (strcmp(provider, "openai") == 0 || strcmp(provider, "openrouter") == 0) {
        snprintf(buf, sizeof(buf), "{\"Authorization\":\"Bearer %s\"}", key);
    } else if (strcmp(provider, "gemini") == 0) {
        snprintf(buf, sizeof(buf), "{\"x-goog-api-key\":\"%s\"}", key);
    } else {
        snprintf(buf, sizeof(buf), "{\"Authorization\":\"Bearer %s\"}", key);
    }

    return strdup(buf);
}
