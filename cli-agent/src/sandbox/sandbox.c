/* sandbox.c — Security enforcement (replaces Rust jenova-sandbox)
 *
 * Path validation (prevent escaping working directory)
 * and command validation for shell execution safety.
 *
 * Uses a layered approach:
 *   1. Deny commands containing known dangerous patterns
 *   2. Deny commands that attempt to obfuscate via encoding/variables
 *   3. Path traversal prevention via realpath resolution
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <ctype.h>
#include "jenova.h"

static const char *blocked_patterns[] = {
    "rm -rf /",
    "rm -fr /",
    "dd if=",
    "mkfs",
    "fdisk",
    ":(){ :|:",
    "> /dev/sd",
    "chmod 777 /",
    "chown root",
    NULL
};

static const char *blocked_substrings[] = {
    "curl|sh",
    "curl|bash",
    "wget|sh",
    "wget|bash",
    "curl | sh",
    "curl | bash",
    "wget | sh",
    "wget | bash",
    NULL
};

static int contains_obfuscation(const char *cmd) {
    if (!cmd) return 0;

    for (const char *p = cmd; *p; p++) {
        if (*p == '\\' && *(p+1) == 'x') return 1;
        if (*p == '$' && *(p+1) == '(') {
            const char *inner = p + 2;
            while (*inner && *inner != ')') {
                if (strncmp(inner, "base64", 6) == 0) return 1;
                if (strncmp(inner, "printf", 6) == 0) return 1;
                inner++;
            }
        }
    }
    return 0;
}

static char *normalize_command(const char *cmd) {
    if (!cmd) return NULL;
    size_t len = strlen(cmd);
    char *normalized = malloc(len + 1);
    if (!normalized) return NULL;

    size_t j = 0;
    int prev_space = 0;
    for (size_t i = 0; i < len; i++) {
        char c = (char)tolower((unsigned char)cmd[i]);
        if (c == ' ' || c == '\t') {
            if (!prev_space && j > 0) {
                normalized[j++] = ' ';
                prev_space = 1;
            }
        } else {
            normalized[j++] = c;
            prev_space = 0;
        }
    }
    while (j > 0 && normalized[j-1] == ' ') j--;
    normalized[j] = '\0';
    return normalized;
}

int32_t jenova_sandbox_validate_path(const char *path, const char *working_dir) {
    if (!path || !working_dir) return 0;

    char resolved_path[PATH_MAX];
    char resolved_dir[PATH_MAX];

    if (!realpath(working_dir, resolved_dir)) {
        return 0;
    }

    if (realpath(path, resolved_path)) {
        size_t dir_len = strlen(resolved_dir);
        if (strncmp(resolved_path, resolved_dir, dir_len) != 0) return 0;
        return resolved_path[dir_len] == '/' || resolved_path[dir_len] == '\0';
    }

    char parent[PATH_MAX];
    strncpy(parent, path, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';

    char *last_slash = strrchr(parent, '/');
    if (last_slash) {
        *last_slash = '\0';
        if (realpath(parent, resolved_path)) {
            size_t dir_len = strlen(resolved_dir);
            if (strncmp(resolved_path, resolved_dir, dir_len) != 0) return 0;
            return resolved_path[dir_len] == '/' || resolved_path[dir_len] == '\0';
        }
    }

    size_t wd_len = strlen(working_dir);
    if (strncmp(path, working_dir, wd_len) != 0) return 0;
    return path[wd_len] == '/' || path[wd_len] == '\0';
}

int32_t jenova_sandbox_validate_command(const char *command) {
    if (!command) return 0;
    if (strlen(command) == 0) return 0;

    if (contains_obfuscation(command)) return 0;

    char *normalized = normalize_command(command);
    if (!normalized) return 0;

    for (int i = 0; blocked_patterns[i]; i++) {
        if (strstr(normalized, blocked_patterns[i]) != NULL) {
            free(normalized);
            return 0;
        }
    }

    for (int i = 0; blocked_substrings[i]; i++) {
        if (strstr(normalized, blocked_substrings[i]) != NULL) {
            free(normalized);
            return 0;
        }
    }

    free(normalized);
    return 1;
}
