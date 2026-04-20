/* fs.c — Filesystem operations (replaces Rust jenova-fs)
 *
 * Read, write, edit, glob, grep, stat, directory operations.
 * Uses POSIX APIs and optionally spawns external tools (grep/find).
 */

/* nftw()/FTW_PHYS live behind _XOPEN_SOURCE=500 on glibc; realpath needs
 * _DEFAULT_SOURCE. Define before any system header include. */
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 500
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif

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
#include <ftw.h>
#include <fnmatch.h>
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



static int shell_quote(const char *src, char *dst, size_t dst_size) {
    if (!src || !dst || dst_size < 3) return -1;
    size_t pos = 0;
    dst[pos++] = '\'';
    for (const char *p = src; *p; p++) {
        if (*p == '\'') {
            if (pos + 4 >= dst_size) return -1;
            dst[pos++] = '\'';
            dst[pos++] = '\\';
            dst[pos++] = '\'';
            dst[pos++] = '\'';
        } else {
            if (pos + 1 >= dst_size) return -1;
            dst[pos++] = *p;
        }
    }
    if (pos + 1 >= dst_size) return -1;
    dst[pos++] = '\'';
    dst[pos] = '\0';
    return 0;
}

static char *json_escape_string(const char *src) {
    if (!src) return strdup("");
    size_t len = strlen(src);
    size_t capacity = len * 2 + 1;
    char *result = malloc(capacity);
    if (!result) return NULL;
    size_t pos = 0;
    for (size_t i = 0; i < len; i++) {
        char c = src[i];
        if (pos + 6 >= capacity) {
            capacity *= 2;
            char *new_r = realloc(result, capacity);
            if (!new_r) { free(result); return NULL; }
            result = new_r;
        }
        switch (c) {
            case '"':  result[pos++] = '\\'; result[pos++] = '"'; break;
            case '\\': result[pos++] = '\\'; result[pos++] = '\\'; break;
            case '\n': result[pos++] = '\\'; result[pos++] = 'n'; break;
            case '\r': result[pos++] = '\\'; result[pos++] = 'r'; break;
            case '\t': result[pos++] = '\\'; result[pos++] = 't'; break;
            default:
                if ((unsigned char)c < 0x20) {
                    pos += (size_t)snprintf(result + pos, capacity - pos, "\\u%04x", (unsigned char)c);
                } else {
                    result[pos++] = c;
                }
                break;
        }
    }
    result[pos] = '\0';
    return result;
}

static struct {
    const char *pattern;
    const char *root;
    size_t root_len;
    /* pattern_tail points at the portion of the pattern after the last
     * "/" (the filename template), used for basename matching when the
     * pattern contains a doublestar. When the pattern has no "**"
     * component this equals `pattern`. */
    const char *pattern_tail;
    /* pattern_prefix: the portion of the pattern before the first "**",
     * with any trailing '/' stripped. For "src/**\/*.c" this is "src";
     * for "**\/*.lua" it's the empty string. Only used when
     * has_doublestar is set — callers must ensure the relative path
     * starts with this prefix so anchored recursive globs don't match
     * paths outside the intended root. */
    char pattern_prefix[PATH_MAX];
    size_t pattern_prefix_len;
    /* has_slash: pattern contains a path separator, meaning fnmatch should
     * consider the relative path, not just the basename. */
    int has_slash;
    /* has_doublestar: pattern contains "**" — recursive match, fall back
     * to basename-only matching using pattern_tail. */
    int has_doublestar;
    char *result;
    size_t capacity;
    size_t pos;
    int count;
    int limit;
    int first;
} glob_ctx;

static int glob_nftw_cb(const char *fpath, const struct stat *sb,
                        int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    if (typeflag != FTW_F) return 0;
    if (glob_ctx.count >= glob_ctx.limit) return 0;

    const char *basename = strrchr(fpath, '/');
    basename = basename ? basename + 1 : fpath;

    /* Compute the relative path below `root` for patterns containing a
     * path separator. If the file path doesn't start with root (unlikely
     * given nftw traversal) fall back to the full fpath. */
    const char *rel = fpath;
    if (glob_ctx.root_len > 0 &&
        strncmp(fpath, glob_ctx.root, glob_ctx.root_len) == 0) {
        rel = fpath + glob_ctx.root_len;
        while (*rel == '/') rel++;
    }

    int matched;
    if (glob_ctx.has_doublestar) {
        /* Recursive glob: require the relative path to start with the
         * anchor prefix (the directory portion before "**"), then match
         * the trailing component against basename. This stops patterns
         * like "src/**\/*.c" from matching files under "other/dir/". */
        if (glob_ctx.pattern_prefix_len > 0) {
            if (strncmp(rel, glob_ctx.pattern_prefix,
                        glob_ctx.pattern_prefix_len) != 0) {
                return 0;
            }
            /* Require a boundary so "src" doesn't match "src_extra". */
            char after = rel[glob_ctx.pattern_prefix_len];
            if (after != '/' && after != '\0') return 0;
        }
        matched = (fnmatch(glob_ctx.pattern_tail, basename, 0) == 0);
    } else if (glob_ctx.has_slash) {
        /* Anchored pattern (e.g. src/foo.c) — match the relative path. */
        matched = (fnmatch(glob_ctx.pattern, rel, FNM_PATHNAME) == 0);
    } else {
        matched = (fnmatch(glob_ctx.pattern, basename, 0) == 0);
    }
    if (!matched) return 0;

    char *escaped = json_escape_string(fpath);
    if (!escaped) return 0;
    size_t len = strlen(escaped);

    while (glob_ctx.pos + len + 8 > glob_ctx.capacity) {
        glob_ctx.capacity *= 2;
        glob_ctx.result = safe_realloc(glob_ctx.result, glob_ctx.capacity);
        if (!glob_ctx.result) { free(escaped); return 1; }
    }

    if (!glob_ctx.first) glob_ctx.result[glob_ctx.pos++] = ',';
    glob_ctx.result[glob_ctx.pos++] = '"';
    memcpy(glob_ctx.result + glob_ctx.pos, escaped, len);
    glob_ctx.pos += len;
    glob_ctx.result[glob_ctx.pos++] = '"';
    glob_ctx.first = 0;
    glob_ctx.count++;
    free(escaped);
    return 0;
}

char *jenova_fs_glob(const char *pattern, const char *root, int32_t max_results) {
    if (!pattern || !root) return NULL;

    glob_ctx.pattern = pattern;
    glob_ctx.root = root;
    glob_ctx.root_len = strlen(root);
    /* Strip trailing slash from root so the relative-path computation
     * doesn't leave an empty component. */
    while (glob_ctx.root_len > 0 && root[glob_ctx.root_len - 1] == '/') {
        glob_ctx.root_len--;
    }
    glob_ctx.has_slash = (strchr(pattern, '/') != NULL);
    glob_ctx.has_doublestar = (strstr(pattern, "**") != NULL);
    /* pattern_tail: text after the last '/' in the pattern, used for
     * basename matching when "**" is present. */
    const char *last_slash = strrchr(pattern, '/');
    glob_ctx.pattern_tail = last_slash ? last_slash + 1 : pattern;
    /* pattern_prefix: directory anchor before the first doublestar token.
     * For "src/<DS>/foo.c" that's "src"; for "<DS>/*.lua" it's empty. */
    glob_ctx.pattern_prefix[0] = '\0';
    glob_ctx.pattern_prefix_len = 0;
    if (glob_ctx.has_doublestar) {
        const char *dstar = strstr(pattern, "**");
        size_t prefix_len = (size_t)(dstar - pattern);
        /* Strip trailing '/' from prefix so "src/" → "src". */
        while (prefix_len > 0 && pattern[prefix_len - 1] == '/') prefix_len--;
        if (prefix_len > 0 && prefix_len < sizeof(glob_ctx.pattern_prefix)) {
            memcpy(glob_ctx.pattern_prefix, pattern, prefix_len);
            glob_ctx.pattern_prefix[prefix_len] = '\0';
            glob_ctx.pattern_prefix_len = prefix_len;
        }
    }
    glob_ctx.limit = max_results > 0 ? max_results : 500;
    glob_ctx.capacity = 4096;
    glob_ctx.result = malloc(glob_ctx.capacity);
    if (!glob_ctx.result) return strdup("[]");
    glob_ctx.result[0] = '[';
    glob_ctx.pos = 1;
    glob_ctx.first = 1;
    glob_ctx.count = 0;

    nftw(root, glob_nftw_cb, 20, FTW_PHYS);

    if (!glob_ctx.result) return strdup("[]");
    glob_ctx.result[glob_ctx.pos++] = ']';
    glob_ctx.result[glob_ctx.pos] = '\0';
    return glob_ctx.result;
}

char *jenova_fs_grep(const char *pattern, const char *root,
                     const char *file_glob, int32_t max_results) {
    if (!pattern || !root) return NULL;

    char q_pattern[2048], q_root[PATH_MAX + 4], q_glob[512];
    if (shell_quote(pattern, q_pattern, sizeof(q_pattern)) != 0) return strdup("[]");
    if (shell_quote(root, q_root, sizeof(q_root)) != 0) return strdup("[]");
    if (file_glob) {
        if (shell_quote(file_glob, q_glob, sizeof(q_glob)) != 0) return strdup("[]");
    }

    /* Use `-rHn` so every match is printed as "file:line_number:content",
     * which we parse into structured JSON for the Lua layer. -F is dropped
     * so Perl-compatible regex (patterns like "(?i)…") work. */
    int cap = max_results > 0 ? max_results : 200;
    char cmd[8192];
    if (file_glob) {
        snprintf(cmd, sizeof(cmd),
                 "grep -rHnP --include=%s -- %s %s 2>/dev/null | head -n %d",
                 q_glob, q_pattern, q_root, cap);
    } else {
        snprintf(cmd, sizeof(cmd),
                 "grep -rHnP -- %s %s 2>/dev/null | head -n %d",
                 q_pattern, q_root, cap);
    }

    FILE *p = popen(cmd, "r");
    if (!p) return strdup("[]");

    size_t capacity = 8192;
    char *result = malloc(capacity);
    if (!result) { pclose(p); return strdup("[]"); }
    strcpy(result, "[");
    size_t pos = 1;
    int first = 1;

    /* grep output can exceed PATH_MAX when lines are long; use a larger buffer. */
    char line[16384];
    while (fgets(line, sizeof(line), p)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
        if (len == 0) continue;

        /* Parse "file:line:content". The filename may contain ':', so we
         * scan for the first ':' followed by digits followed by ':'. */
        char *first_colon = strchr(line, ':');
        if (!first_colon) continue;
        char *scan = first_colon;
        char *line_num_end = NULL;
        while (scan) {
            char *digits = scan + 1;
            char *after = digits;
            while (*after >= '0' && *after <= '9') after++;
            if (after > digits && *after == ':') {
                line_num_end = after;
                first_colon = scan;
                break;
            }
            scan = strchr(scan + 1, ':');
        }
        if (!line_num_end) continue;

        *first_colon = '\0';
        char *line_num_str = first_colon + 1;
        *line_num_end = '\0';
        const char *content = line_num_end + 1;

        char *esc_file = json_escape_string(line);
        char *esc_content = json_escape_string(content);
        if (!esc_file || !esc_content) {
            free(esc_file); free(esc_content);
            continue;
        }

        size_t entry_cap = strlen(esc_file) + strlen(esc_content) + strlen(line_num_str) + 64;
        while (pos + entry_cap > capacity) {
            capacity *= 2;
            result = safe_realloc(result, capacity);
            if (!result) {
                free(esc_file); free(esc_content);
                pclose(p); return strdup("[]");
            }
        }

        int written = snprintf(result + pos, capacity - pos,
                               "%s{\"file\":\"%s\",\"line_number\":%s,\"content\":\"%s\"}",
                               first ? "" : ",", esc_file, line_num_str, esc_content);
        if (written > 0) pos += (size_t)written;
        first = 0;
        free(esc_file);
        free(esc_content);
    }
    pclose(p);

    if (pos + 2 > capacity) {
        result = safe_realloc(result, pos + 2);
        if (!result) return strdup("[]");
    }
    result[pos++] = ']';
    result[pos] = '\0';
    return result;
}

char *jenova_fs_stat(const char *path) {
    if (!path) return NULL;

    struct stat st;
    if (stat(path, &st) != 0) return NULL;

    char *escaped_path = json_escape_string(path);
    if (!escaped_path) return NULL;

    char buf[1024];
    snprintf(buf, sizeof(buf),
             "{\"path\":\"%s\",\"size\":%lld,\"is_file\":%s,\"is_dir\":%s,"
             "\"is_symlink\":%s,\"modified\":%lld,\"permissions\":%o}",
             escaped_path, (long long)st.st_size,
             S_ISREG(st.st_mode) ? "true" : "false",
             S_ISDIR(st.st_mode) ? "true" : "false",
             S_ISLNK(st.st_mode) ? "true" : "false",
             (long long)st.st_mtime,
             (unsigned int)(st.st_mode & 0777));
    free(escaped_path);
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

        char *escaped_name = json_escape_string(entry->d_name);
        if (!escaped_name) continue;

        size_t escaped_len = strlen(escaped_name);
        while (pos + escaped_len + 32 > capacity) {
            capacity *= 2;
            result = safe_realloc(result, capacity);
            if (!result) { free(escaped_name); closedir(dir); return NULL; }
        }

        if (!first) result[pos++] = ',';
        pos += (size_t)snprintf(result + pos, capacity - pos,
                                "{\"name\":\"%s\",\"is_dir\":%s}",
                                escaped_name,
                                is_dir ? "true" : "false");
        free(escaped_name);
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
    char q_path[PATH_MAX + 4];
    if (shell_quote(path, q_path, sizeof(q_path)) != 0) return -1;
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", q_path);
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
