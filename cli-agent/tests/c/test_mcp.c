/* test_mcp.c — Unit tests for MCP JSON-RPC id handling and message classification
 *
 * Covers the three scenarios called out in Copilot review 4145880903:
 *   1. Request with "id":0 must respond with "id":0 (not "id":null).
 *   2. Request with missing id must not emit a numeric id (emit "id":null).
 *   3. Messages where "method" appears only inside a string value must not
 *      be classified as a request.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "jenova.h"

static int tests_run    = 0;
static int tests_passed = 0;

/* ── Assertion macros ──────────────────────────────────────────────────── */

#define ASSERT_STR_CONTAINS(haystack, needle, msg) do { \
    tests_run++; \
    const char *_h = (haystack); \
    const char *_n = (needle); \
    if (_h && _n && strstr(_h, _n)) { \
        tests_passed++; \
    } else { \
        fprintf(stderr, "  FAIL [%s] (line %d): '%s' not found in '%s'\n", \
                msg, __LINE__, _n ? _n : "(null)", _h ? _h : "(null)"); \
    } \
} while(0)

#define ASSERT_STR_NOT_CONTAINS(haystack, needle, msg) do { \
    tests_run++; \
    const char *_h = (haystack); \
    const char *_n = (needle); \
    if (_h && _n && !strstr(_h, _n)) { \
        tests_passed++; \
    } else { \
        fprintf(stderr, "  FAIL [%s] (line %d): '%s' was found in '%s' but should not be\n", \
                msg, __LINE__, _n ? _n : "(null)", _h ? _h : "(null)"); \
    } \
} while(0)

#define ASSERT_STR_EQ(got, expected, msg) do { \
    tests_run++; \
    const char *_g = (got); \
    const char *_e = (expected); \
    if (_g && _e && strcmp(_g, _e) == 0) { \
        tests_passed++; \
    } else { \
        fprintf(stderr, "  FAIL [%s] (line %d): got '%s', expected '%s'\n", \
                msg, __LINE__, _g ? _g : "(null)", _e ? _e : "(null)"); \
    } \
} while(0)

/* ── Scenario 1: id == 0 ───────────────────────────────────────────────── */

/* jenova_mcp_handle_message must reply with "id":0 (not "id":null) when the
 * incoming request carries "id":0. */
static void test_id_zero_ping(void) {
    printf("  ping with id:0 must reply id:0...\n");
    const char *msg = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"ping\"}";
    char *resp = jenova_mcp_handle_message(msg);
    ASSERT_STR_CONTAINS(resp, "\"id\":0", "id:0 ping response contains id:0");
    ASSERT_STR_NOT_CONTAINS(resp, "\"id\":null", "id:0 ping response does not contain id:null");
    free(resp);
}

static void test_id_zero_unknown_method(void) {
    printf("  unknown method with id:0 must reply id:0...\n");
    const char *msg = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"unknownMethod\"}";
    char *resp = jenova_mcp_handle_message(msg);
    ASSERT_STR_CONTAINS(resp, "\"id\":0", "id:0 error response contains id:0");
    ASSERT_STR_NOT_CONTAINS(resp, "\"id\":null", "id:0 error response does not contain id:null");
    ASSERT_STR_CONTAINS(resp, "\"error\"", "id:0 error response contains error field");
    free(resp);
}

/* jenova_mcp_parse_message must classify a request with id:0 as "request",
 * not "notification" (since id is present). */
static void test_id_zero_classification(void) {
    printf("  parse_message: request with id:0 is classified as request...\n");
    const char *msg = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"foo\"}";
    char *parsed = jenova_mcp_parse_message(msg);
    ASSERT_STR_CONTAINS(parsed, "request", "id:0 message classified as request");
    free(parsed);
}

/* ── Scenario 2: missing id → no numeric id in response ──────────────── */

static void test_missing_id_notification(void) {
    printf("  parse_message: message without id is classified as notification...\n");
    const char *msg = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    char *parsed = jenova_mcp_parse_message(msg);
    ASSERT_STR_CONTAINS(parsed, "notification", "no-id message classified as notification");
    free(parsed);
}

static void test_missing_id_handle(void) {
    printf("  handle_message: missing id must reply with id:null, not id:0...\n");
    const char *msg = "{\"jsonrpc\":\"2.0\",\"method\":\"unknownMethod\"}";
    char *resp = jenova_mcp_handle_message(msg);
    ASSERT_STR_CONTAINS(resp, "\"id\":null", "missing-id response contains id:null");
    /* Must not emit a numeric 0 after "id": */
    const char *id0 = strstr(resp, "\"id\":0");
    if (id0 && (id0[6] < '0' || id0[6] > '9')) {
        /* "id":0 without another digit — this is the bad case */
        fprintf(stderr, "  FAIL [missing-id response must not contain id:0]: got '%s'\n", resp);
        tests_run++;
    } else {
        tests_run++;
        tests_passed++;
    }
    free(resp);
}

/* ── Scenario 3: "method" only inside a string value — false positive ─── */

static void test_method_in_string_value_not_request(void) {
    printf("  parse_message: 'method' inside a string value must not classify as request...\n");

    /* "method" appears only as a value, not a top-level key. */
    const char *msg = "{\"note\":\"this has a method field but no real method key\",\"result\":{}}";
    char *parsed = jenova_mcp_parse_message(msg);
    ASSERT_STR_NOT_CONTAINS(parsed, "request", "method-in-string-value not classified as request");
    free(parsed);
}

static void test_method_in_nested_object_not_request(void) {
    printf("  parse_message: 'method' in nested object must not classify as request...\n");

    const char *msg = "{\"data\":{\"method\":\"nested\"},\"result\":{}}";
    char *parsed = jenova_mcp_parse_message(msg);
    ASSERT_STR_NOT_CONTAINS(parsed, "request", "method-in-nested-object not classified as request");
    ASSERT_STR_CONTAINS(parsed, "response", "message with result field classified as response");
    free(parsed);
}

/* ── Scenario 3 extended: result/error inside string value ──────────────── */

static void test_result_in_string_value_not_response(void) {
    printf("  parse_message: 'result' inside a string value must not classify as response...\n");

    /* No top-level result/error/method — should be unknown */
    const char *msg = "{\"info\":\"contains result and error strings\"}";
    char *parsed = jenova_mcp_parse_message(msg);
    ASSERT_STR_EQ(parsed, "{\"type\":\"unknown\"}", "no-method/result/error message is unknown");
    free(parsed);
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(void) {
    printf("=== MCP JSON-RPC Unit Tests ===\n");

    printf("\n-- id:0 handling --\n");
    test_id_zero_ping();
    test_id_zero_unknown_method();
    test_id_zero_classification();

    printf("\n-- missing id handling --\n");
    test_missing_id_notification();
    test_missing_id_handle();

    printf("\n-- method/result/error in string value (false-positive guard) --\n");
    test_method_in_string_value_not_request();
    test_method_in_nested_object_not_request();
    test_result_in_string_value_not_response();

    printf("\nResults: %d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
