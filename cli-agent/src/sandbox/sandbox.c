/* sandbox.c — Security enforcement (replaces Rust jenova-sandbox)
 *
 * Path validation (prevent escaping working directory)
 * and command allowlisting for shell execution safety.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "jenova.h"

static const char *blocked_commands[] = {
    "rm -rf /", "dd if=", "mkfs", "fdisk", "mount",
    "chmod 777 /", ":(){ :|:", "curl|sh", "wget|sh",
    NULL
};

int32_t jenova_sandbox_validate_path(const char *path, const char *working_dir) {
    if (!path || !working_dir) return 0;

    char resolved_path[PATH_MAX];
    char resolved_dir[PATH_MAX];

    if (!realpath(working_dir, resolved_dir)) {
        return 0;
    }

    if (realpath(path, resolved_path)) {
        return strncmp(resolved_path, resolved_dir, strlen(resolved_dir)) == 0;
    }

    char parent[PATH_MAX];
    strncpy(parent, path, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';

    char *last_slash = strrchr(parent, '/');
    if (last_slash) {
        *last_slash = '\0';
        if (realpath(parent, resolved_path)) {
            return strncmp(resolved_path, resolved_dir, strlen(resolved_dir)) == 0;
        }
    }

    return strncmp(path, working_dir, strlen(working_dir)) == 0;
}

int32_t jenova_sandbox_validate_command(const char *command) {
    if (!command) return 0;

    for (int i = 0; blocked_commands[i]; i++) {
        if (strstr(command, blocked_commands[i]) != NULL) {
            return 0;
        }
    }
    return 1;
}
