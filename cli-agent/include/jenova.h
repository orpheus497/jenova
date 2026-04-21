/* jenova.h — Pure C service layer declarations for cli-agent
 *
 * Replaces the Rust FFI layer entirely with native C implementations.
 * All services (HTTP, auth, JSON, crypto, sandbox, fs, process, MCP, llama.cpp)
 * are implemented in C11, linked directly against system libraries.
 *
 * Architecture: Lua (app) → C host (Lua VM + bindings) → C services → llama.cpp
 */

#ifndef JENOVA_H
#define JENOVA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Initialization ────────────────────────────────────────────────────── */

int32_t jenova_init(void);
void    jenova_shutdown(void);
const char *jenova_version(void);
void    jenova_free_string(char *ptr);

/* ── HTTP Client (src/net/) ────────────────────────────────────────────── */

typedef struct jenova_http_response {
    int32_t  status_code;
    char    *body;
    char    *headers_json;
    char    *error;
} jenova_http_response_t;

jenova_http_response_t *jenova_http_get(const char *url, const char *headers_json);
jenova_http_response_t *jenova_http_post(const char *url, const char *headers_json,
                                         const char *body, const char *content_type);
jenova_http_response_t *jenova_http_post_json(const char *url, const char *headers_json,
                                              const char *body);
jenova_http_response_t *jenova_http_post_stream(const char *url, const char *headers_json,
                                                const char *body);
void jenova_http_response_free(jenova_http_response_t *resp);

/* SSE streaming callback */
typedef void (*jenova_sse_callback)(const char *event, const char *data, void *userdata);
int32_t jenova_http_stream_sse(const char *url, const char *headers_json,
                               const char *body, jenova_sse_callback cb, void *userdata);

/* ── Authentication (src/auth/) ────────────────────────────────────────── */

int32_t jenova_auth_validate_key(const char *provider, const char *key);
char   *jenova_auth_resolve_key(const char *provider);
int32_t jenova_auth_store_key(const char *provider, const char *key);
int32_t jenova_auth_delete_key(const char *provider);
char   *jenova_auth_build_headers(const char *provider, const char *key);

/* ── Sandbox (src/sandbox/) ────────────────────────────────────────────── */

int32_t jenova_sandbox_validate_path(const char *path, const char *working_dir);
int32_t jenova_sandbox_validate_command(const char *command);

/* ── JSON (src/json/) ──────────────────────────────────────────────────── */

char *jenova_json_parse(const char *json_str);
char *jenova_json_stringify(const char *json_str);
char *jenova_json_get(const char *json_str, const char *path);
void  jenova_json_free(char *ptr);

/* ── Crypto (src/crypto/) ──────────────────────────────────────────────── */

char   *jenova_crypto_sha256(const char *input);
char   *jenova_crypto_hmac_sha256(const char *key, const char *data);
char   *jenova_crypto_uuid(void);
char   *jenova_crypto_random_hex(int32_t byte_len);
char   *jenova_crypto_base64_encode(const char *data, size_t len);
/* Returns a binary buffer (may contain NUL bytes); length written to *out_len.
 * Free with jenova_crypto_free(). */
unsigned char *jenova_crypto_base64_decode(const char *input, size_t *out_len);
void    jenova_crypto_free(char *ptr);

/* ── Process Management (src/process/) ─────────────────────────────────── */

typedef struct jenova_process_result {
    char    *stdout_buf;
    char    *stderr_buf;
    int32_t  exit_code;
    int32_t  timed_out;
    int64_t  duration_ms;
} jenova_process_result_t;

jenova_process_result_t *jenova_process_spawn(const char *command, const char *cwd,
                                              int32_t timeout_ms);
jenova_process_result_t *jenova_process_spawn_json(const char *config_json);
void jenova_process_result_free(jenova_process_result_t *result);
const char *jenova_process_platform_shell(void);

/* ── File System (src/fs/) ─────────────────────────────────────────────── */

char   *jenova_fs_read(const char *path, int32_t offset, int32_t limit);
int32_t jenova_fs_write(const char *path, const char *content);
char   *jenova_fs_edit(const char *path, const char *old_string,
                       const char *new_string, int32_t replace_all);
char   *jenova_fs_glob(const char *pattern, const char *root, int32_t max_results);
char   *jenova_fs_grep(const char *pattern, const char *root,
                       const char *file_glob, int32_t max_results);
char   *jenova_fs_stat(const char *path);
int32_t jenova_fs_mkdir(const char *path);
int32_t jenova_fs_exists(const char *path);
int32_t jenova_fs_is_dir(const char *path);
char   *jenova_fs_list_dir(const char *path);
int32_t jenova_fs_remove(const char *path);
int32_t jenova_fs_remove_recursive(const char *path);
int64_t jenova_fs_copy(const char *src, const char *dst);
int32_t jenova_fs_rename(const char *src, const char *dst);

/* ── MCP Protocol (src/mcp/) ──────────────────────────────────────────── */

char *jenova_mcp_build_init_request(void);
char *jenova_mcp_parse_message(const char *message);
char *jenova_mcp_handle_message(const char *message);

/* ── llama.cpp Integration (src/llama/) ────────────────────────────────── */

uint32_t jenova_llama_load_model(const char *model_path, const char *config_json);
void     jenova_llama_unload_model(uint32_t model_id);
char    *jenova_llama_generate(uint32_t model_id, const char *prompt, const char *params_json);
uint32_t jenova_llama_count_tokens(uint32_t model_id, const char *text);
char    *jenova_llama_list_models(void);
char    *jenova_llama_find_model(const char *name);

/* Streaming generation callback */
typedef int (*jenova_llama_stream_cb)(const char *token, void *userdata);
int32_t jenova_llama_generate_stream(uint32_t model_id, const char *prompt,
                                     const char *params_json,
                                     jenova_llama_stream_cb cb, void *userdata);

/* ── Agent Core (src/agent/) ──────────────────────────────────────────── */

typedef struct jenova_agent_config {
    const char *system_prompt;
    const char *model;
    int32_t     max_turns;
    int32_t     context_size;
    int32_t     enable_tools;
    int32_t     enable_memory;
} jenova_agent_config_t;

int32_t jenova_agent_init(const jenova_agent_config_t *config);
void    jenova_agent_shutdown(void);
char   *jenova_agent_run_turn(const char *user_message);
int32_t jenova_agent_reset(void);
char   *jenova_agent_get_state_json(void);

/* ── LSP Bridge (src/agent/) ──────────────────────────────────────────── */
/* Forwards an LSP JSON-RPC request to a running language server via stdin/
 * stdout (stdio transport). Returns the response JSON string or NULL.     */
char *jenova_lsp_request(const char *request_json);

/* ── System Utilities ─────────────────────────────────────────────────── */
int32_t jenova_system_setenv(const char *name, const char *value);

#ifdef __cplusplus
}
#endif

#endif /* JENOVA_H */
