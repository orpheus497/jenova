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
    /* Writing to critical system files. The substring "/etc/passwd"
     * after `>`/`>>` would be ideal, but strstr can match regardless
     * of direction — any command mentioning these paths for write
     * intent should already be running under different privileges. */
    ">/etc/passwd",
    "> /etc/passwd",
    ">>/etc/passwd",
    ">> /etc/passwd",
    ">/etc/shadow",
    "> /etc/shadow",
    ">>/etc/shadow",
    ">> /etc/shadow",
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
    char candidate[PATH_MAX];

    if (!realpath(working_dir, resolved_dir)) {
        return 0;
    }

    if (path[0] != '/') {
        int n = snprintf(candidate, sizeof(candidate), "%s/%s", resolved_dir, path);
        if (n < 0 || (size_t)n >= sizeof(candidate)) return 0;
    } else {
        strncpy(candidate, path, sizeof(candidate) - 1);
        candidate[sizeof(candidate) - 1] = '\0';
    }

    if (realpath(candidate, resolved_path)) {
        size_t dir_len = strlen(resolved_dir);
        if (strncmp(resolved_path, resolved_dir, dir_len) != 0) return 0;
        return resolved_path[dir_len] == '/' || resolved_path[dir_len] == '\0';
    }

    char parent[PATH_MAX];
    strncpy(parent, candidate, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';

    char *last_slash = strrchr(parent, '/');
    if (last_slash) {
        if (last_slash == parent) {
            last_slash[1] = '\0';
        } else {
            *last_slash = '\0';
        }
        if (realpath(parent, resolved_path)) {
            size_t dir_len = strlen(resolved_dir);
            if (strncmp(resolved_path, resolved_dir, dir_len) != 0) return 0;
            return resolved_path[dir_len] == '/' || resolved_path[dir_len] == '\0';
        }
    }

    size_t dir_len = strlen(resolved_dir);
    if (strncmp(candidate, resolved_dir, dir_len) != 0) return 0;
    return candidate[dir_len] == '/' || candidate[dir_len] == '\0';
}

int32_t jenova_sandbox_validate_command(const char *command) {
    if (!command) return 0;
    if (strlen(command) == 0) return 0;

    if (contains_obfuscation(command)) return 0;

    /* CR/LF in a command argument is almost always a log-injection attempt
     * or a multi-command smuggle — reject. Backticks allow arbitrary
     * subshell execution without the `$(...)` form the obfuscation check
     * inspects, so keep them off the allowlist as well. Shell composition
     * characters (`&`, `;`, `|`, `>`, `<`, `$`) are intentionally allowed
     * — blocked_patterns/blocked_substrings below handle the dangerous
     * combinations, and real coding workflows require pipes and chains
     * (e.g. "git add . && git commit", "cat file | head"). */
    for (const char *p = command; *p; p++) {
        if (*p == '\n' || *p == '\r' || *p == '`') return 0;
    }

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

    /* Detect the "curl/wget <URL> | sh/bash" remote-execution pattern even
     * when the URL sits between the fetcher and the pipe, and even when
     * absolute paths are used (e.g. "/usr/bin/curl http://x | /bin/sh").
     * strstr("curl") matches "/usr/bin/curl" naturally since "curl" is a
     * substring. For the shell side, we scan every '|' occurrence and
     * inspect the first whitespace-delimited token after it to see
     * whether it's a shell (possibly via an absolute path). */
    int has_fetcher = (strstr(normalized, "curl") != NULL) ||
                      (strstr(normalized, "wget") != NULL) ||
                      (strstr(normalized, "fetch") != NULL);
    if (has_fetcher) {
        static const char *shells[] = {
            "sh", "bash", "zsh", "ksh", "dash", "ash", "csh", "tcsh",
            "fish", "python", "python3", "perl", "ruby", "node", NULL
        };
        for (const char *p = normalized; *p; p++) {
            if (*p != '|') continue;
            /* Skip past the pipe and any whitespace. */
            const char *t = p + 1;
            while (*t == ' ' || *t == '\t') t++;
            /* Skip a leading absolute/relative path so "|/bin/sh" and
             * "|./script.sh" still resolve to their basename. */
            const char *base = t;
            for (const char *s = t; *s && *s != ' ' && *s != '\t' &&
                                    *s != '\n' && *s != ';' && *s != '|' &&
                                    *s != '&' && *s != '>'; s++) {
                if (*s == '/') base = s + 1;
            }
            /* Determine token end. */
            const char *end = base;
            while (*end && *end != ' ' && *end != '\t' && *end != '\n' &&
                   *end != ';' && *end != '|' && *end != '&' && *end != '>') {
                end++;
            }
            size_t token_len = (size_t)(end - base);
            if (token_len == 0) continue;
            for (int i = 0; shells[i]; i++) {
                size_t sl = strlen(shells[i]);
                if (sl == token_len && strncmp(base, shells[i], sl) == 0) {
                    free(normalized);
                    return 0;
                }
            }
        }
    }

    free(normalized);
    return 1;
}
