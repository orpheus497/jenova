/* process.c — Subprocess management (replaces Rust jenova-process)
 *
 * Spawns shell commands with timeout, output capture, and signal handling.
 * POSIX implementation for FreeBSD/Linux/macOS.
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

static int64_t time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)ts.tv_nsec / 1000000;
}

const char *jenova_process_platform_shell(void) {
#if defined(__FreeBSD__)
    return "/bin/sh";
#elif defined(__APPLE__)
    return "/bin/zsh";
#else
    return "/bin/sh";
#endif
}

jenova_process_result_t *jenova_process_spawn(const char *command, const char *cwd,
                                              int32_t timeout_ms) {
    if (!command) return NULL;

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
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        if (cwd && chdir(cwd) != 0) {
            _exit(127);
        }

        const char *shell = jenova_process_platform_shell();
        execl(shell, shell, "-c", command, (char *)NULL);
        _exit(127);
    }

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

        char tmp[4096];
        ssize_t n;
        while ((n = read(stdout_pipe[0], tmp, sizeof(tmp))) > 0) {
            while (stdout_len + (size_t)n + 1 > stdout_cap) {
                stdout_cap *= 2;
                char *new_buf = realloc(stdout_buf, stdout_cap);
                if (!new_buf) { free(stdout_buf); stdout_buf = NULL; goto drain_done; }
                stdout_buf = new_buf;
            }
            memcpy(stdout_buf + stdout_len, tmp, (size_t)n);
            stdout_len += (size_t)n;
        }
        while ((n = read(stderr_pipe[0], tmp, sizeof(tmp))) > 0) {
            while (stderr_len + (size_t)n + 1 > stderr_cap) {
                stderr_cap *= 2;
                char *new_buf = realloc(stderr_buf, stderr_cap);
                if (!new_buf) { free(stderr_buf); stderr_buf = NULL; goto drain_done; }
                stderr_buf = new_buf;
            }
            memcpy(stderr_buf + stderr_len, tmp, (size_t)n);
            stderr_len += (size_t)n;
        }

        usleep(10000);
    }

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

drain_done:
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

static char *json_extract_string(const char *json, const char *key) {
    if (!json || !key) return NULL;

    char search_key[256];
    snprintf(search_key, sizeof(search_key), "\"%s\"", key);

    const char *pos = strstr(json, search_key);
    if (!pos) return NULL;

    pos += strlen(search_key);
    while (*pos == ' ' || *pos == '\t' || *pos == ':') pos++;
    if (*pos != '"') return NULL;
    pos++;

    size_t capacity = 256;
    char *result = malloc(capacity);
    if (!result) return NULL;
    size_t len = 0;

    while (*pos && *pos != '"') {
        if (len + 2 > capacity) {
            capacity *= 2;
            char *new_result = realloc(result, capacity);
            if (!new_result) { free(result); return NULL; }
            result = new_result;
        }
        if (*pos == '\\' && *(pos+1)) {
            pos++;
            switch (*pos) {
                case 'n': result[len++] = '\n'; break;
                case 't': result[len++] = '\t'; break;
                case '\\': result[len++] = '\\'; break;
                case '"': result[len++] = '"'; break;
                case '/': result[len++] = '/'; break;
                default: result[len++] = *pos; break;
            }
        } else {
            result[len++] = *pos;
        }
        pos++;
    }
    result[len] = '\0';
    return result;
}

static int32_t json_extract_int(const char *json, const char *key, int32_t default_val) {
    if (!json || !key) return default_val;

    char search_key[256];
    snprintf(search_key, sizeof(search_key), "\"%s\"", key);

    const char *pos = strstr(json, search_key);
    if (!pos) return default_val;

    pos += strlen(search_key);
    while (*pos == ' ' || *pos == '\t' || *pos == ':') pos++;

    return atoi(pos);
}

static int shell_quote_arg(const char *src, size_t src_len, char *dst, size_t dst_size) {
    if (!src || !dst || dst_size < 3) return -1;
    size_t pos = 0;
    dst[pos++] = '\'';
    for (size_t i = 0; i < src_len; i++) {
        if (src[i] == '\'') {
            if (pos + 4 >= dst_size) return -1;
            dst[pos++] = '\'';
            dst[pos++] = '\\';
            dst[pos++] = '\'';
            dst[pos++] = '\'';
        } else {
            if (pos + 1 >= dst_size) return -1;
            dst[pos++] = src[i];
        }
    }
    if (pos + 1 >= dst_size) return -1;
    dst[pos++] = '\'';
    dst[pos] = '\0';
    return (int)pos;
}

static char *json_extract_args_command(const char *json) {
    if (!json) return NULL;

    const char *args_pos = strstr(json, "\"args\"");
    if (!args_pos) return NULL;

    args_pos += 6;
    while (*args_pos == ' ' || *args_pos == '\t' || *args_pos == ':') args_pos++;
    if (*args_pos != '[') return NULL;
    args_pos++;

    size_t capacity = 1024;
    char *command = malloc(capacity);
    if (!command) return NULL;
    size_t cmd_len = 0;
    command[0] = '\0';

    int in_string = 0;
    int first_arg = 1;
    const char *str_start = NULL;

    for (const char *p = args_pos; *p && *p != ']'; p++) {
        if (!in_string) {
            if (*p == '"') {
                in_string = 1;
                str_start = p + 1;
            }
        } else {
            if (*p == '\\' && *(p+1)) {
                p++;
                continue;
            }
            if (*p == '"') {
                size_t arg_len = (size_t)(p - str_start);
                char quoted[4096];
                int qlen = shell_quote_arg(str_start, arg_len, quoted, sizeof(quoted));
                if (qlen < 0) { free(command); return NULL; }

                while (cmd_len + (size_t)qlen + 2 > capacity) {
                    capacity *= 2;
                    char *new_cmd = realloc(command, capacity);
                    if (!new_cmd) { free(command); return NULL; }
                    command = new_cmd;
                }
                if (!first_arg) command[cmd_len++] = ' ';
                memcpy(command + cmd_len, quoted, (size_t)qlen);
                cmd_len += (size_t)qlen;
                command[cmd_len] = '\0';
                first_arg = 0;
                in_string = 0;
            }
        }
    }

    if (cmd_len == 0) { free(command); return NULL; }
    return command;
}

jenova_process_result_t *jenova_process_spawn_json(const char *config_json) {
    if (!config_json) return NULL;

    char *command = json_extract_string(config_json, "command");
    if (!command) return NULL;

    char *args_cmd = json_extract_args_command(config_json);
    char *final_command = NULL;

    if (args_cmd) {
        size_t cmd_len = strlen(command) + 1 + strlen(args_cmd) + 1;
        final_command = malloc(cmd_len);
        if (final_command) {
            snprintf(final_command, cmd_len, "%s %s", command, args_cmd);
        }
        free(args_cmd);
    }

    if (!final_command) {
        final_command = strdup(command);
    }
    free(command);

    if (!final_command) return NULL;

    int32_t timeout_ms = json_extract_int(config_json, "timeout_ms", 30000);
    char *cwd = json_extract_string(config_json, "cwd");

    jenova_process_result_t *result = jenova_process_spawn(final_command, cwd, timeout_ms);
    free(final_command);
    free(cwd);
    return result;
}

void jenova_process_result_free(jenova_process_result_t *result) {
    if (!result) return;
    free(result->stdout_buf);
    free(result->stderr_buf);
    free(result);
}
