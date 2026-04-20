/* fs.c — Filesystem operations (replaces Rust jenova-fs)
 *
 * Read, write, edit, glob, grep, stat, directory operations.
 * Uses POSIX APIs and optionally spawns external tools (grep/find).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <limits.h>
#include <glob.h>
#include "jenova.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static char *safe_realloc(char *ptr, size_t new_size) {
    char *new_ptr = realloc(ptr, new_size);
    if (!new_ptr) {
        free(ptr);
        return NULL;
    }
    return new_ptr;
}

char *jenova_fs_read(const char *path, int32_t offset, int32_t limit) {
    if (!path) return NULL;

    FILE *f = fopen(path, "r");
    if (!f) return NULL;

    fseeko(f, 0, SEEK_END);
    off_t file_size = ftello(f);
    fseeko(f, 0, SEEK_SET);

    if (file_size < 0) {
        fclose(f);
        return NULL;
    }

    if (offset > 0 || limit > 0) {
        size_t capacity = 8192;
        char *result = malloc(capacity);
        if (!result) { fclose(f); return NULL; }
        size_t pos = 0;
        int line_num = 0;
        char line[4096];

        while (fgets(line, sizeof(line), f)) {
            line_num++;
            if (line_num <= offset) continue;
            if (limit > 0 && line_num > offset + limit) break;

            size_t line_len = strlen(line);
            while (pos + line_len + 32 > capacity) {
                capacity *= 2;
                result = safe_realloc(result, capacity);
                if (!result) { fclose(f); return NULL; }
            }
            int n = snprintf(result + pos, capacity - pos, "%6d|%s", line_num, line);
            pos += (size_t)n;
        }
        result[pos] = '\0';
        fclose(f);
        return result;
    }

    char *content = malloc((size_t)file_size + 1);
    if (!content) { fclose(f); return NULL; }
    size_t read_bytes = fread(content, 1, (size_t)file_size, f);
    content[read_bytes] = '\0';
    fclose(f);
    return content;
}

int32_t jenova_fs_write(const char *path, const char *content) {
    if (!path || !content) return -1;

    FILE *f = fopen(path, "w");
    if (!f) return -1;

    size_t len = strlen(content);
    size_t written = fwrite(content, 1, len, f);
    fclose(f);
    return (written == len) ? 0 : -1;
}

char *jenova_fs_edit(const char *path, const char *old_string,
                     const char *new_string, int32_t replace_all) {
    if (!path || !old_string || !new_string) return NULL;

    char *content = jenova_fs_read(path, 0, 0);
    if (!content) return strdup("{\"error\":\"file not found\"}");

    char *found = strstr(content, old_string);
    if (!found) {
        free(content);
        return strdup("{\"error\":\"old_string not found in file\"}");
    }

    size_t old_len = strlen(old_string);
    size_t new_len = strlen(new_string);
    size_t content_len = strlen(content);

    int count = 0;
    char *search = content;
    while ((search = strstr(search, old_string)) != NULL) {
        count++;
        search += old_len;
        if (!replace_all) break;
    }

    size_t result_len = content_len + (size_t)count * (new_len - old_len);
    char *result = malloc(result_len + 1);
    if (!result) { free(content); return strdup("{\"error\":\"allocation failed\"}"); }
    char *rp = result;
    char *cp = content;

    int replaced = 0;
    while (*cp) {
        if (strncmp(cp, old_string, old_len) == 0 && (replace_all || replaced == 0)) {
            memcpy(rp, new_string, new_len);
            rp += new_len;
            cp += old_len;
            replaced++;
        } else {
            *rp++ = *cp++;
        }
    }
    *rp = '\0';

    FILE *f = fopen(path, "w");
    if (f) {
        fwrite(result, 1, strlen(result), f);
        fclose(f);
    }

    free(content);
    free(result);

    char response[128];
    snprintf(response, sizeof(response), "{\"replacements\":%d}", replaced);
    return strdup(response);
}

static int has_shell_metachar(const char *s) {
    while (*s) {
        switch (*s) {
            case '\'': case '"': case '\\': case '`':
            case '$': case '&': case '|': case ';':
            case '<': case '>': case '(': case ')':
            case '{': case '}': case '\n': case '\r':
                return 1;
        }
        s++;
    }
    return 0;
}

char *jenova_fs_glob(const char *pattern, const char *root, int32_t max_results) {
    if (!pattern || !root) return NULL;
    if (has_shell_metachar(root)) return strdup("[]");

    char glob_pattern[PATH_MAX];
    snprintf(glob_pattern, sizeof(glob_pattern), "%s/**/%s", root, pattern);

    glob_t globbuf;
    int flags = GLOB_NOSORT;
#ifdef GLOB_BRACE
    flags |= GLOB_BRACE;
#endif

    int ret = glob(glob_pattern, flags, NULL, &globbuf);
    if (ret != 0 && ret != GLOB_NOMATCH) {
        snprintf(glob_pattern, sizeof(glob_pattern), "%s/%s", root, pattern);
        ret = glob(glob_pattern, flags, NULL, &globbuf);
    }

    if (ret != 0) return strdup("[]");

    int limit = max_results > 0 ? max_results : 500;
    size_t capacity = 4096;
    char *result = malloc(capacity);
    if (!result) { globfree(&globbuf); return strdup("[]"); }
    strcpy(result, "[");
    size_t pos = 1;
    int first = 1;

    for (size_t i = 0; i < globbuf.gl_pathc && i < (size_t)limit; i++) {
        const char *path = globbuf.gl_pathv[i];
        size_t len = strlen(path);

        while (pos + len + 8 > capacity) {
            capacity *= 2;
            result = safe_realloc(result, capacity);
            if (!result) { globfree(&globbuf); return strdup("[]"); }
        }

        if (!first) result[pos++] = ',';
        result[pos++] = '"';
        memcpy(result + pos, path, len);
        pos += len;
        result[pos++] = '"';
        first = 0;
    }
    globfree(&globbuf);

    result[pos++] = ']';
    result[pos] = '\0';
    return result;
}

char *jenova_fs_grep(const char *pattern, const char *root,
                     const char *file_glob, int32_t max_results) {
    if (!pattern || !root) return NULL;
    if (has_shell_metachar(pattern) || has_shell_metachar(root)) return strdup("[]");
    if (file_glob && has_shell_metachar(file_glob)) return strdup("[]");

    char cmd[2048];
    if (file_glob) {
        snprintf(cmd, sizeof(cmd),
                 "grep -rlF --include='%s' -- '%s' '%s' 2>/dev/null | head -n %d",
                 file_glob, pattern, root, max_results > 0 ? max_results : 200);
    } else {
        snprintf(cmd, sizeof(cmd),
                 "grep -rlF -- '%s' '%s' 2>/dev/null | head -n %d",
                 pattern, root, max_results > 0 ? max_results : 200);
    }

    FILE *p = popen(cmd, "r");
    if (!p) return strdup("[]");

    size_t capacity = 4096;
    char *result = malloc(capacity);
    if (!result) { pclose(p); return strdup("[]"); }
    strcpy(result, "[");
    size_t pos = 1;
    int first = 1;

    char line[PATH_MAX];
    while (fgets(line, sizeof(line), p)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
        if (len == 0) continue;

        while (pos + len + 8 > capacity) {
            capacity *= 2;
            result = safe_realloc(result, capacity);
            if (!result) { pclose(p); return strdup("[]"); }
        }

        if (!first) result[pos++] = ',';
        result[pos++] = '"';
        memcpy(result + pos, line, len);
        pos += len;
        result[pos++] = '"';
        first = 0;
    }
    pclose(p);

    result[pos++] = ']';
    result[pos] = '\0';
    return result;
}

char *jenova_fs_stat(const char *path) {
    if (!path) return NULL;

    struct stat st;
    if (stat(path, &st) != 0) return NULL;

    char buf[512];
    snprintf(buf, sizeof(buf),
             "{\"path\":\"%s\",\"size\":%lld,\"is_file\":%s,\"is_dir\":%s,"
             "\"is_symlink\":%s,\"modified\":%lld,\"permissions\":%o}",
             path, (long long)st.st_size,
             S_ISREG(st.st_mode) ? "true" : "false",
             S_ISDIR(st.st_mode) ? "true" : "false",
             S_ISLNK(st.st_mode) ? "true" : "false",
             (long long)st.st_mtime,
             (unsigned int)(st.st_mode & 0777));
    return strdup(buf);
}

int32_t jenova_fs_mkdir(const char *path) {
    if (!path) return -1;

    char tmp[PATH_MAX];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';

    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    return mkdir(tmp, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

int32_t jenova_fs_exists(const char *path) {
    if (!path) return 0;
    return access(path, F_OK) == 0;
}

int32_t jenova_fs_is_dir(const char *path) {
    if (!path) return 0;
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
}

char *jenova_fs_list_dir(const char *path) {
    if (!path) return NULL;

    DIR *dir = opendir(path);
    if (!dir) return NULL;

    size_t capacity = 4096;
    char *result = malloc(capacity);
    if (!result) { closedir(dir); return NULL; }
    strcpy(result, "[");
    size_t pos = 1;
    int first = 1;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;

        int is_dir = 0;
#ifdef DT_DIR
        is_dir = (entry->d_type == DT_DIR);
#else
        struct stat st;
        char full_path[PATH_MAX];
        snprintf(full_path, sizeof(full_path), "%s/%s", path, entry->d_name);
        if (stat(full_path, &st) == 0) is_dir = S_ISDIR(st.st_mode);
#endif

        size_t name_len = strlen(entry->d_name);
        while (pos + name_len + 16 > capacity) {
            capacity *= 2;
            result = safe_realloc(result, capacity);
            if (!result) { closedir(dir); return NULL; }
        }

        if (!first) result[pos++] = ',';
        pos += (size_t)snprintf(result + pos, capacity - pos,
                                "{\"name\":\"%s\",\"is_dir\":%s}",
                                entry->d_name,
                                is_dir ? "true" : "false");
        first = 0;
    }
    closedir(dir);

    result[pos++] = ']';
    result[pos] = '\0';
    return result;
}

int32_t jenova_fs_remove(const char *path) {
    if (!path) return -1;
    return unlink(path);
}

int32_t jenova_fs_remove_recursive(const char *path) {
    if (!path) return -1;
    if (has_shell_metachar(path)) return -1;
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", path);
    return system(cmd) == 0 ? 0 : -1;
}

int64_t jenova_fs_copy(const char *src, const char *dst) {
    if (!src || !dst) return -1;

    FILE *in = fopen(src, "rb");
    if (!in) return -1;

    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }

    char buf[8192];
    int64_t total = 0;
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        fwrite(buf, 1, n, out);
        total += (int64_t)n;
    }

    fclose(in);
    fclose(out);
    return total;
}

int32_t jenova_fs_rename(const char *src, const char *dst) {
    if (!src || !dst) return -1;
    return rename(src, dst);
}
