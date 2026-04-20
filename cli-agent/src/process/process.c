/* process.c — Subprocess management (replaces Rust jenova-process)
 *
 * Spawns shell commands with timeout, output capture, and signal handling.
 * POSIX implementation for FreeBSD/Linux/macOS.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
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
                stdout_buf = realloc(stdout_buf, stdout_cap);
            }
            memcpy(stdout_buf + stdout_len, tmp, (size_t)n);
            stdout_len += (size_t)n;
        }
        while ((n = read(stderr_pipe[0], tmp, sizeof(tmp))) > 0) {
            while (stderr_len + (size_t)n + 1 > stderr_cap) {
                stderr_cap *= 2;
                stderr_buf = realloc(stderr_buf, stderr_cap);
            }
            memcpy(stderr_buf + stderr_len, tmp, (size_t)n);
            stderr_len += (size_t)n;
        }

        usleep(10000);
    }

    char tmp[4096];
    ssize_t n;
    while ((n = read(stdout_pipe[0], tmp, sizeof(tmp))) > 0) {
        while (stdout_len + (size_t)n + 1 > stdout_cap) {
            stdout_cap *= 2;
            stdout_buf = realloc(stdout_buf, stdout_cap);
        }
        memcpy(stdout_buf + stdout_len, tmp, (size_t)n);
        stdout_len += (size_t)n;
    }
    while ((n = read(stderr_pipe[0], tmp, sizeof(tmp))) > 0) {
        while (stderr_len + (size_t)n + 1 > stderr_cap) {
            stderr_cap *= 2;
            stderr_buf = realloc(stderr_buf, stderr_cap);
        }
        memcpy(stderr_buf + stderr_len, tmp, (size_t)n);
        stderr_len += (size_t)n;
    }

    close(stdout_pipe[0]);
    close(stderr_pipe[0]);

    stdout_buf[stdout_len] = '\0';
    stderr_buf[stderr_len] = '\0';

    result->stdout_buf = stdout_buf;
    result->stderr_buf = stderr_buf;
    result->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    result->timed_out = timed_out;
    result->duration_ms = time_ms() - start_time;

    return result;
}

jenova_process_result_t *jenova_process_spawn_json(const char *config_json) {
    if (!config_json) return NULL;

    const char *cmd_start = strstr(config_json, "\"command\"");
    if (!cmd_start) return NULL;

    cmd_start = strchr(cmd_start + 9, '"');
    if (!cmd_start) return NULL;
    cmd_start++;

    const char *cmd_end = strchr(cmd_start, '"');
    if (!cmd_end) return NULL;

    size_t cmd_len = (size_t)(cmd_end - cmd_start);
    char *command = malloc(cmd_len + 1);
    memcpy(command, cmd_start, cmd_len);
    command[cmd_len] = '\0';

    int32_t timeout_ms = 30000;
    const char *timeout_str = strstr(config_json, "\"timeout_ms\"");
    if (timeout_str) {
        timeout_str = strchr(timeout_str + 12, ':');
        if (timeout_str) timeout_ms = atoi(timeout_str + 1);
    }

    char *cwd = NULL;
    const char *cwd_start = strstr(config_json, "\"cwd\"");
    if (cwd_start) {
        cwd_start = strchr(cwd_start + 5, '"');
        if (cwd_start) {
            cwd_start++;
            const char *cwd_end = strchr(cwd_start, '"');
            if (cwd_end) {
                size_t cwd_len = (size_t)(cwd_end - cwd_start);
                cwd = malloc(cwd_len + 1);
                memcpy(cwd, cwd_start, cwd_len);
                cwd[cwd_len] = '\0';
            }
        }
    }

    jenova_process_result_t *result = jenova_process_spawn(command, cwd, timeout_ms);
    free(command);
    free(cwd);
    return result;
}

void jenova_process_result_free(jenova_process_result_t *result) {
    if (!result) return;
    free(result->stdout_buf);
    free(result->stderr_buf);
    free(result);
}
