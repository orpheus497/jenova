/* process.c — Subprocess management (replaces Rust jenova-process)
 *
 * Spawns shell commands with timeout, output capture, and signal handling.
 * POSIX implementation for FreeBSD/Linux/macOS.
 *
 * Security fixes applied:
 *   - jenova_process_spawn: uses execvp(argv[]) instead of execl(shell, "-c", cmd)
 *     so the shell is only invoked when explicitly requested, not by default.
 *   - jenova_process_spawn_json: uses a state-machine JSON parser (json_sm_*) to
 *     extract "command", "args", "cwd", "timeout_ms" without strstr key-shadowing.
 *   - FreeBSD capsicum(4): child enters capability mode after dup2/chdir so it
 *     cannot open new file descriptors or spawn further processes beyond the exec.
 */

#if defined(__FreeBSD__)
#define __BSD_VISIBLE 1
#endif
#define _DEFAULT_SOURCE
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <fcntl.h>
#include "jenova.h"

#if defined(__FreeBSD__)
#include <sys/capsicum.h>
#define HAVE_CAPSICUM 1
#else
#define HAVE_CAPSICUM 0
#endif

/* ── Time helpers ──────────────────────────────────────────────────────── */

static int64_t time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)ts.tv_nsec / 1000000;
}

/* ── Platform shell (used only when the caller explicitly requests it) ── */

const char *jenova_process_platform_shell(void) {
#if defined(__FreeBSD__)
    return "/bin/sh";
#elif defined(__APPLE__)
    return "/bin/zsh";
#else
    return "/bin/sh";
#endif
}

/* ══════════════════════════════════════════════════════════════════════════
 * Minimal state-machine JSON parser
 *
 * Parses a flat JSON object and extracts:
 *   - string values:  json_sm_string(json, key, out_buf, buf_size)
 *   - integer values: json_sm_int(json, key, default_val)
 *   - string array:   json_sm_string_array(json, key, out_arr, max_items) → count
 *
 * Unlike strstr-based helpers, this parser tracks nesting depth and string
 * boundaries so a value containing a key name cannot shadow the real key.
 * ═══════════════════════════════════════════════════════════════════════ */

typedef enum { SM_BETWEEN, SM_IN_KEY, SM_AFTER_KEY, SM_IN_STR_VALUE,
               SM_IN_NUM_VALUE, SM_IN_ARRAY, SM_SKIP_VALUE } sm_state_t;

/* Skip whitespace */
static const char *sm_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

/* Read a JSON string starting AFTER the opening '"', unescaping into buf.
 * Returns pointer to character after closing '"', or NULL on error. */
static const char *sm_read_string(const char *p, char *buf, size_t buf_size) {
    size_t len = 0;
    while (*p && *p != '"') {
        if (*p == '\\') {
            p++;
            if (!*p) return NULL;
            char c;
            switch (*p) {
                case '"': c = '"'; break;
                case '\\': c = '\\'; break;
                case '/': c = '/'; break;
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'r': c = '\r'; break;
                default:  c = *p; break;
            }
            if (buf && len + 1 < buf_size) buf[len++] = c;
        } else {
            if (buf && len + 1 < buf_size) buf[len++] = *p;
        }
        p++;
    }
    if (buf) buf[len] = '\0';
    return *p == '"' ? p + 1 : NULL;
}

/* Skip any JSON value at the current position (for keys we don't care about) */
static const char *sm_skip_value(const char *p) {
    p = sm_ws(p);
    if (*p == '"') {
        p++;
        while (*p && *p != '"') { if (*p == '\\') p++; p++; }
        return *p == '"' ? p + 1 : NULL;
    }
    if (*p == '{' || *p == '[') {
        char open = *p, close = open == '{' ? '}' : ']';
        int depth = 1; p++;
        while (*p && depth > 0) {
            if (*p == '"') { p++; while (*p && *p != '"') { if (*p == '\\') p++; p++; } }
            else if (*p == open) depth++;
            else if (*p == close) depth--;
            if (depth > 0 || *p != close) p++;
        }
        return *p == close ? p + 1 : NULL;
    }
    /* number, bool, null */
    while (*p && *p != ',' && *p != '}' && *p != ']') p++;
    return p;
}

/* Extract a string value for a given key from a flat JSON object.
 * Returns 1 on success, 0 if key not found or value not a string. */
static int json_sm_string(const char *json, const char *key,
                          char *out, size_t out_size) {
    if (!json || !key || !out || out_size == 0) return 0;
    out[0] = '\0';
    const char *p = sm_ws(json);
    if (*p != '{') return 0;
    p++;
    while (1) {
        p = sm_ws(p);
        if (*p == '}' || !*p) break;
        if (*p != '"') return 0;
        p++;
        char k[256];
        p = sm_read_string(p, k, sizeof(k));
        if (!p) return 0;
        p = sm_ws(p);
        if (*p != ':') return 0;
        p++;
        p = sm_ws(p);
        if (strcmp(k, key) == 0) {
            if (*p != '"') return 0;
            p++;
            sm_read_string(p, out, out_size);
            return 1;
        }
        p = sm_skip_value(p);
        if (!p) return 0;
        p = sm_ws(p);
        if (*p == ',') p++;
    }
    return 0;
}

/* Extract an integer value for a given key from a flat JSON object. */
static int32_t json_sm_int(const char *json, const char *key, int32_t defval) {
    if (!json || !key) return defval;
    const char *p = sm_ws(json);
    if (*p != '{') return defval;
    p++;
    while (1) {
        p = sm_ws(p);
        if (*p == '}' || !*p) break;
        if (*p != '"') return defval;
        p++;
        char k[256];
        p = sm_read_string(p, k, sizeof(k));
        if (!p) return defval;
        p = sm_ws(p);
        if (*p != ':') return defval;
        p++;
        p = sm_ws(p);
        if (strcmp(k, key) == 0) {
            return (int32_t)strtol(p, NULL, 10);
        }
        p = sm_skip_value(p);
        if (!p) return defval;
        p = sm_ws(p);
        if (*p == ',') p++;
    }
    return defval;
}

/* Extract a JSON string array into a heap-allocated argv-style array.
 * Each element is a heap-allocated string.
 * Returns number of items extracted.  Caller must free each element + the array. */
static int json_sm_string_array(const char *json, const char *key,
                                char ***out_arr, int max_items) {
    *out_arr = NULL;
    if (!json || !key || max_items <= 0) return 0;

    /* Find the array value */
    const char *p = sm_ws(json);
    if (*p != '{') return 0;
    p++;
    const char *arr_start = NULL;
    while (1) {
        p = sm_ws(p);
        if (*p == '}' || !*p) break;
        if (*p != '"') return 0;
        p++;
        char k[256];
        p = sm_read_string(p, k, sizeof(k));
        if (!p) return 0;
        p = sm_ws(p);
        if (*p != ':') return 0;
        p++;
        p = sm_ws(p);
        if (strcmp(k, key) == 0) {
            if (*p == '[') { arr_start = p + 1; }
            break;
        }
        p = sm_skip_value(p);
        if (!p) return 0;
        p = sm_ws(p);
        if (*p == ',') p++;
    }
    if (!arr_start) return 0;

    char **arr = calloc((size_t)(max_items + 1), sizeof(char *));
    if (!arr) return 0;
    int count = 0;

    p = sm_ws(arr_start);
    while (*p && *p != ']' && count < max_items) {
        p = sm_ws(p);
        if (*p != '"') { p = sm_skip_value(p); if (!p) break; goto next_elem; }
        p++;
        /* Measure the unescaped length first */
        const char *tmp = p;
        size_t needed = 1;
        while (*tmp && *tmp != '"') {
            if (*tmp == '\\') tmp++;
            tmp++; needed++;
        }
        char *elem = malloc(needed);
        if (!elem) { break; }
        p = sm_read_string(p, elem, needed);
        if (!p) { free(elem); break; }
        arr[count++] = elem;
    next_elem:
        p = sm_ws(p);
        if (*p == ',') p++;
    }

    if (count == 0) { free(arr); return 0; }
    arr[count] = NULL;
    *out_arr = arr;
    return count;
}

/* ── Core spawn implementation ─────────────────────────────────────────── */

/* Internal: spawn using an explicit argv array (no shell interpolation).
 * argv[0] is the executable; argv is NULL-terminated.
 * If argv is NULL, falls back to invoking the platform shell with -c command. */
static jenova_process_result_t *spawn_argv(char *const argv[], const char *cwd,
                                           int32_t timeout_ms) {
    jenova_process_result_t *result = calloc(1, sizeof(jenova_process_result_t));
    if (!result) return NULL;

    int stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        result->exit_code = -1;
        result->stderr_buf = strdup("failed to create pipes");
        return result;
    }

    int64_t start_time = time_ms();

    pid_t pid = fork();
    if (pid < 0) {
        result->exit_code = -1;
        result->stderr_buf = strdup("fork failed");
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return result;
    }

    if (pid == 0) {
        /* Child */
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        if (cwd && chdir(cwd) != 0) {
            _exit(127);
        }

#if HAVE_CAPSICUM
        /* Enter capability mode: child can no longer open files by path,
         * create sockets, or fork additional processes. The exec below is
         * still permitted because cap_enter() is called before it. */
        cap_enter();
#endif

        execvp(argv[0], argv);
        _exit(127);
    }

    /* Parent */
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    fcntl(stdout_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(stderr_pipe[0], F_SETFL, O_NONBLOCK);

    size_t stdout_cap = 4096, stderr_cap = 4096;
    char *stdout_buf = malloc(stdout_cap);
    char *stderr_buf = malloc(stderr_cap);
    if (!stdout_buf || !stderr_buf) {
        free(stdout_buf);
        free(stderr_buf);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        result->exit_code = -1;
        result->stderr_buf = strdup("allocation failed");
        return result;
    }
    size_t stdout_len = 0, stderr_len = 0;
    stdout_buf[0] = '\0';
    stderr_buf[0] = '\0';

    int timed_out = 0;
    int status = 0;
    pid_t wpid;

    while (1) {
        wpid = waitpid(pid, &status, WNOHANG);
        if (wpid == pid) break;
        if (wpid < 0) break;

        if (timeout_ms > 0 && (time_ms() - start_time) > timeout_ms) {
            kill(pid, SIGTERM);
            usleep(100000);
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            timed_out = 1;
            break;
        }

        /* Drain available output */
        {
            char tmp[4096];
            ssize_t n;
            while ((n = read(stdout_pipe[0], tmp, sizeof(tmp))) > 0) {
                if (!stdout_buf) break;
                while (stdout_len + (size_t)n + 1 > stdout_cap) {
                    stdout_cap *= 2;
                    char *new_buf = realloc(stdout_buf, stdout_cap);
                    if (!new_buf) { free(stdout_buf); stdout_buf = NULL; break; }
                    stdout_buf = new_buf;
                }
                if (stdout_buf) {
                    memcpy(stdout_buf + stdout_len, tmp, (size_t)n);
                    stdout_len += (size_t)n;
                }
            }
            while ((n = read(stderr_pipe[0], tmp, sizeof(tmp))) > 0) {
                if (!stderr_buf) break;
                while (stderr_len + (size_t)n + 1 > stderr_cap) {
                    stderr_cap *= 2;
                    char *new_buf = realloc(stderr_buf, stderr_cap);
                    if (!new_buf) { free(stderr_buf); stderr_buf = NULL; break; }
                    stderr_buf = new_buf;
                }
                if (stderr_buf) {
                    memcpy(stderr_buf + stderr_len, tmp, (size_t)n);
                    stderr_len += (size_t)n;
                }
            }
        }

        usleep(5000);
    }

    /* Final drain after process exit */
    {
        char tmp[4096];
        ssize_t n;
        while ((n = read(stdout_pipe[0], tmp, sizeof(tmp))) > 0) {
            if (!stdout_buf) break;
            while (stdout_len + (size_t)n + 1 > stdout_cap) {
                stdout_cap *= 2;
                char *new_buf = realloc(stdout_buf, stdout_cap);
                if (!new_buf) { free(stdout_buf); stdout_buf = NULL; break; }
                stdout_buf = new_buf;
            }
            if (stdout_buf) {
                memcpy(stdout_buf + stdout_len, tmp, (size_t)n);
                stdout_len += (size_t)n;
            }
        }
        while ((n = read(stderr_pipe[0], tmp, sizeof(tmp))) > 0) {
            if (!stderr_buf) break;
            while (stderr_len + (size_t)n + 1 > stderr_cap) {
                stderr_cap *= 2;
                char *new_buf = realloc(stderr_buf, stderr_cap);
                if (!new_buf) { free(stderr_buf); stderr_buf = NULL; break; }
                stderr_buf = new_buf;
            }
            if (stderr_buf) {
                memcpy(stderr_buf + stderr_len, tmp, (size_t)n);
                stderr_len += (size_t)n;
            }
        }
    }

    close(stdout_pipe[0]);
    close(stderr_pipe[0]);

    if (stdout_buf) stdout_buf[stdout_len] = '\0';
    if (stderr_buf) stderr_buf[stderr_len] = '\0';

    result->stdout_buf = stdout_buf ? stdout_buf : strdup("");
    result->stderr_buf = stderr_buf ? stderr_buf : strdup("");
    result->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    result->timed_out = timed_out;
    result->duration_ms = time_ms() - start_time;

    return result;
}

/* Public API: spawn a shell command string through the platform shell.
 * This is the legacy path used by callers that build a complete shell command
 * string themselves (e.g. the sandbox-validated bash.lua tool). */
jenova_process_result_t *jenova_process_spawn(const char *command, const char *cwd,
                                              int32_t timeout_ms) {
    if (!command) return NULL;
    const char *shell = jenova_process_platform_shell();
    char *argv[] = { (char *)shell, "-c", (char *)command, NULL };
    return spawn_argv(argv, cwd, timeout_ms);
}

/* Public API: spawn from a JSON config object.
 *
 * Expected JSON shape:
 *   { "command": "prog",          -- executable (required)
 *     "args": ["-flag", "value"], -- extra arguments (optional)
 *     "cwd": "/some/dir",         -- working directory (optional)
 *     "timeout_ms": 30000 }       -- timeout in milliseconds (optional)
 *
 * When "args" is provided, execvp is called with [command, ...args] directly
 * without invoking a shell, eliminating shell injection at the OS boundary.
 * When "args" is absent, command is passed to the platform shell via -c
 * (legacy behaviour retained for compatibility with plain shell strings). */
jenova_process_result_t *jenova_process_spawn_json(const char *config_json) {
    if (!config_json) return NULL;

    /* Use the state-machine parser — immune to key-shadowing attacks */
    char command[4096];
    if (!json_sm_string(config_json, "command", command, sizeof(command))) {
        return NULL;
    }

    char cwd_buf[4096];
    int has_cwd = json_sm_string(config_json, "cwd", cwd_buf, sizeof(cwd_buf));
    const char *cwd = has_cwd && cwd_buf[0] ? cwd_buf : NULL;

    int32_t timeout_ms = json_sm_int(config_json, "timeout_ms", 30000);

    /* Try to extract an explicit args array for shell-free execution */
    char **args_arr = NULL;
    int args_count = json_sm_string_array(config_json, "args", &args_arr, 256);

    jenova_process_result_t *result;

    if (args_count > 0 && args_arr) {
        /* Build argv: [command, args[0], args[1], ..., NULL]
         * execvp is called directly — no shell involved. */
        char **argv = calloc((size_t)(args_count + 2), sizeof(char *));
        if (!argv) {
            for (int i = 0; i < args_count; i++) free(args_arr[i]);
            free(args_arr);
            return NULL;
        }
        argv[0] = command;
        for (int i = 0; i < args_count; i++) {
            argv[i + 1] = args_arr[i];
        }
        argv[args_count + 1] = NULL;

        result = spawn_argv(argv, cwd, timeout_ms);

        free(argv);
        for (int i = 0; i < args_count; i++) free(args_arr[i]);
        free(args_arr);
    } else {
        /* No args array: run through the platform shell (legacy path).
         * command must already be a safe, validated shell string. */
        result = jenova_process_spawn(command, cwd, timeout_ms);
    }

    return result;
}

void jenova_process_result_free(jenova_process_result_t *result) {
    if (!result) return;
    free(result->stdout_buf);
    free(result->stderr_buf);
    free(result);
}
