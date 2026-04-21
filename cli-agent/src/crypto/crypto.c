/* crypto.c — Cryptographic utilities (replaces Rust jenova-crypto)
 *
 * SHA-256, HMAC-SHA256, UUID v4, base64, secure random.
 * Uses OpenSSL (libcrypto) on FreeBSD/Linux/macOS.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include "jenova.h"

#ifndef HAS_OPENSSL
#ifdef __has_include
#if __has_include(<openssl/sha.h>)
#define HAS_OPENSSL 1
#else
#define HAS_OPENSSL 0
#endif
#else
#define HAS_OPENSSL 0
#endif
#endif

#if HAS_OPENSSL
#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/evp.h>
#endif

static void hex_encode(const unsigned char *data, size_t len, char *out) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2]     = hex[data[i] >> 4];
        out[i * 2 + 1] = hex[data[i] & 0x0f];
    }
    out[len * 2] = '\0';
}

static int get_random_bytes(unsigned char *buf, size_t len) {
#if HAS_OPENSSL
    return RAND_bytes(buf, (int)len) == 1 ? 0 : -1;
#else
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    size_t total = 0;
    while (total < len) {
        ssize_t n = read(fd, (char *)buf + total, len - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (n == 0) { close(fd); return -1; }
        total += (size_t)n;
    }
    close(fd);
    return 0;
#endif
}

char *jenova_crypto_sha256(const char *input) {
    if (!input) return NULL;

#if !HAS_OPENSSL
    (void)input;
    return NULL;
#else
    unsigned char hash[32];
    SHA256((const unsigned char *)input, strlen(input), hash);
    char *hex = malloc(65);
    if (!hex) return NULL;
    hex_encode(hash, 32, hex);
    return hex;
#endif
}

char *jenova_crypto_hmac_sha256(const char *key, const char *data) {
    if (!key || !data) return NULL;

#if !HAS_OPENSSL
    (void)key;
    (void)data;
    return NULL;
#else
    unsigned char result[32];
    unsigned int result_len = 32;
    HMAC(EVP_sha256(), key, (int)strlen(key),
         (const unsigned char *)data, strlen(data), result, &result_len);
    char *hex = malloc(65);
    if (!hex) return NULL;
    hex_encode(result, 32, hex);
    return hex;
#endif
}

char *jenova_crypto_uuid(void) {
    unsigned char bytes[16];
    if (get_random_bytes(bytes, 16) != 0) return NULL;

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    char *uuid = malloc(37);
    if (!uuid) return NULL;
    snprintf(uuid, 37, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             bytes[0], bytes[1], bytes[2], bytes[3],
             bytes[4], bytes[5], bytes[6], bytes[7],
             bytes[8], bytes[9], bytes[10], bytes[11],
             bytes[12], bytes[13], bytes[14], bytes[15]);
    return uuid;
}

char *jenova_crypto_random_hex(int32_t byte_len) {
    if (byte_len <= 0 || byte_len > 256) byte_len = 16;

    unsigned char *bytes = malloc((size_t)byte_len);
    if (get_random_bytes(bytes, (size_t)byte_len) != 0) {
        free(bytes);
        return NULL;
    }

    char *hex = malloc((size_t)(byte_len * 2 + 1));
    hex_encode(bytes, (size_t)byte_len, hex);
    free(bytes);
    return hex;
}

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

char *jenova_crypto_base64_encode(const char *data, size_t len) {
    if (!data) return NULL;

    size_t out_len = 4 * ((len + 2) / 3);
    char *out = malloc(out_len + 1);
    if (!out) return NULL;

    size_t i, j;
    for (i = 0, j = 0; i < len; i += 3, j += 4) {
        uint32_t n = ((uint32_t)(unsigned char)data[i]) << 16;
        if (i + 1 < len) n |= ((uint32_t)(unsigned char)data[i+1]) << 8;
        if (i + 2 < len) n |= (uint32_t)(unsigned char)data[i+2];

        out[j]   = b64_table[(n >> 18) & 0x3f];
        out[j+1] = b64_table[(n >> 12) & 0x3f];
        out[j+2] = (i + 1 < len) ? b64_table[(n >> 6) & 0x3f] : '=';
        out[j+3] = (i + 2 < len) ? b64_table[n & 0x3f] : '=';
    }
    out[j] = '\0';
    return out;
}

static int b64_decode_char(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

char *jenova_crypto_base64_decode(const char *input, size_t *out_len) {
    if (!input) return NULL;

    size_t in_len = strlen(input);
    if (in_len == 0) { if (out_len) *out_len = 0; return strdup(""); }
    if (in_len % 4 != 0) return NULL;

    size_t decoded_len = in_len / 4 * 3;
    if (input[in_len - 1] == '=') decoded_len--;
    if (input[in_len - 2] == '=') decoded_len--;

    char *out = malloc(decoded_len + 1);
    if (!out) return NULL;
    size_t j = 0;

    for (size_t i = 0; i < in_len; i += 4) {
        int a = b64_decode_char(input[i]);
        int b = b64_decode_char(input[i+1]);
        int c = (input[i+2] == '=') ? 0 : b64_decode_char(input[i+2]);
        int d = (input[i+3] == '=') ? 0 : b64_decode_char(input[i+3]);

        if (a < 0 || b < 0 ||
            (input[i+2] != '=' && c < 0) ||
            (input[i+3] != '=' && d < 0)) { free(out); return NULL; }

        uint32_t n = ((uint32_t)a << 18) | ((uint32_t)b << 12) | ((uint32_t)c << 6) | (uint32_t)d;
        if (j < decoded_len) out[j++] = (char)((n >> 16) & 0xff);
        if (j < decoded_len) out[j++] = (char)((n >> 8) & 0xff);
        if (j < decoded_len) out[j++] = (char)(n & 0xff);
    }

    out[decoded_len] = '\0';
    if (out_len) *out_len = decoded_len;
    return out;
}

void jenova_crypto_free(char *ptr) {
    free(ptr);
}
