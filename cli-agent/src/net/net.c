/* net.c — HTTP client using libcurl (replaces Rust jenova-net)
 *
 * Provides GET, POST, and streaming SSE support.
 * Uses libcurl for portable HTTP on FreeBSD/Linux/macOS.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include "jenova.h"

typedef struct {
    char  *data;
    size_t size;
    size_t capacity;
} buffer_t;

static void buffer_init(buffer_t *buf) {
    buf->capacity = 4096;
    buf->data = malloc(buf->capacity);
    if (!buf->data) { buf->capacity = 0; buf->size = 0; return; }
    buf->data[0] = '\0';
    buf->size = 0;
}

static void buffer_append(buffer_t *buf, const char *data, size_t len) {
    if (!buf->data) return;
    while (buf->size + len + 1 > buf->capacity) {
        buf->capacity *= 2;
        char *tmp = realloc(buf->data, buf->capacity);
        if (!tmp) return;
        buf->data = tmp;
    }
    memcpy(buf->data + buf->size, data, len);
    buf->size += len;
    buf->data[buf->size] = '\0';
}

static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t total = size * nmemb;
    buffer_t *buf = (buffer_t *)userp;
    buffer_append(buf, contents, total);
    return total;
}

static const char *find_unescaped_quote(const char *p) {
    while (*p) {
        if (*p == '\\') { p += 2; continue; }
        if (*p == '"') return p;
        p++;
    }
    return NULL;
}

static size_t unescape_json_string(const char *src, size_t src_len, char *dst, size_t dst_size) {
    size_t out = 0;
    for (size_t i = 0; i < src_len && out + 1 < dst_size; i++) {
        if (src[i] == '\\' && i + 1 < src_len) {
            i++;
            switch (src[i]) {
                case '"': dst[out++] = '"'; break;
                case '\\': dst[out++] = '\\'; break;
                case '/': dst[out++] = '/'; break;
                case 'n': dst[out++] = '\n'; break;
                case 't': dst[out++] = '\t'; break;
                default: dst[out++] = src[i]; break;
            }
        } else {
            dst[out++] = src[i];
        }
    }
    dst[out] = '\0';
    return out;
}

static struct curl_slist *parse_headers_json(const char *headers_json) {
    struct curl_slist *headers = NULL;
    if (!headers_json || headers_json[0] == '\0') return NULL;

    const char *p = headers_json;
    while (*p) {
        const char *key_start = strchr(p, '"');
        if (!key_start) break;
        key_start++;
        const char *key_end = find_unescaped_quote(key_start);
        if (!key_end) break;

        size_t key_len = (size_t)(key_end - key_start);
        char key[512];
        if (key_len >= sizeof(key)) { p = key_end + 1; continue; }
        unescape_json_string(key_start, key_len, key, sizeof(key));

        p = key_end + 1;
        while (*p && *p != '"') p++;
        if (!*p) break;
        p++;
        const char *val_end = find_unescaped_quote(p);
        if (!val_end) break;

        size_t val_len = (size_t)(val_end - p);
        char val[1024];
        if (val_len >= sizeof(val)) { p = val_end + 1; continue; }
        unescape_json_string(p, val_len, val, sizeof(val));

        char header[2048];
        snprintf(header, sizeof(header), "%s: %s", key, val);
        headers = curl_slist_append(headers, header);

        p = val_end + 1;
    }
    return headers;
}

static jenova_http_response_t *do_request(const char *url, const char *headers_json,
                                          const char *body, const char *method) {
    jenova_http_response_t *resp = calloc(1, sizeof(jenova_http_response_t));
    if (!resp) return NULL;

    CURL *curl = curl_easy_init();
    if (!curl) {
        resp->error = strdup("failed to initialize curl");
        return resp;
    }

    buffer_t response_buf;
    buffer_init(&response_buf);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "cli-agent/0.2.0");

    struct curl_slist *curl_headers = parse_headers_json(headers_json);

    if (body && strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        if (!curl_headers || !strstr(headers_json ? headers_json : "", "Content-Type")) {
            curl_headers = curl_slist_append(curl_headers, "Content-Type: application/json");
        }
    }

    if (curl_headers) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, curl_headers);
    }

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        resp->error = strdup(curl_easy_strerror(res));
        free(response_buf.data);
    } else {
        long http_code = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
        resp->status_code = (int32_t)http_code;
        resp->body = response_buf.data;
    }

    if (curl_headers) curl_slist_free_all(curl_headers);
    curl_easy_cleanup(curl);
    return resp;
}

jenova_http_response_t *jenova_http_get(const char *url, const char *headers_json) {
    return do_request(url, headers_json, NULL, "GET");
}

jenova_http_response_t *jenova_http_post(const char *url, const char *headers_json,
                                         const char *body, const char *content_type) {
    (void)content_type;
    return do_request(url, headers_json, body, "POST");
}

jenova_http_response_t *jenova_http_post_json(const char *url, const char *headers_json,
                                              const char *body) {
    return do_request(url, headers_json, body, "POST");
}

jenova_http_response_t *jenova_http_post_stream(const char *url, const char *headers_json,
                                                const char *body) {
    return do_request(url, headers_json, body, "POST");
}

void jenova_http_response_free(jenova_http_response_t *resp) {
    if (!resp) return;
    free(resp->body);
    free(resp->headers_json);
    free(resp->error);
    free(resp);
}

/* SSE streaming */
typedef struct {
    jenova_sse_callback callback;
    void *userdata;
    buffer_t line_buf;
} sse_context_t;

static size_t sse_write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t total = size * nmemb;
    sse_context_t *ctx = (sse_context_t *)userp;
    const char *data = (const char *)contents;

    for (size_t i = 0; i < total; i++) {
        if (data[i] == '\n') {
            if (ctx->line_buf.size > 0) {
                if (strncmp(ctx->line_buf.data, "data: ", 6) == 0) {
                    ctx->callback("message", ctx->line_buf.data + 6, ctx->userdata);
                } else if (strncmp(ctx->line_buf.data, "event: ", 7) == 0) {
                    ctx->callback("event", ctx->line_buf.data + 7, ctx->userdata);
                }
                ctx->line_buf.size = 0;
                ctx->line_buf.data[0] = '\0';
            }
        } else {
            buffer_append(&ctx->line_buf, &data[i], 1);
        }
    }
    return total;
}

int32_t jenova_http_stream_sse(const char *url, const char *headers_json,
                               const char *body, jenova_sse_callback cb, void *userdata) {
    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    sse_context_t ctx = {0};
    ctx.callback = cb;
    ctx.userdata = userdata;
    buffer_init(&ctx.line_buf);

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, sse_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "cli-agent/0.2.0");

    struct curl_slist *curl_headers = parse_headers_json(headers_json);
    curl_headers = curl_slist_append(curl_headers, "Accept: text/event-stream");

    if (body) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        curl_headers = curl_slist_append(curl_headers, "Content-Type: application/json");
    }

    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, curl_headers);

    CURLcode res = curl_easy_perform(curl);

    if (curl_headers) curl_slist_free_all(curl_headers);
    free(ctx.line_buf.data);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK) ? 0 : -1;
}
