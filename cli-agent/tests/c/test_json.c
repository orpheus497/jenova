/* test_json.c — Unit tests for jenova_json_get() */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "jenova.h"

static int tests_run = 0;
static int tests_passed = 0;

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

#define ASSERT_NULL(got, msg) do { \
    tests_run++; \
    if ((got) == NULL) { tests_passed++; } \
    else { fprintf(stderr, "  FAIL [%s] (line %d): expected NULL, got '%s'\n", \
                   msg, __LINE__, (got)); } \
} while(0)

static void test_simple_string(void) {
    printf("  simple string values...\n");
    char *v;

    v = jenova_json_get("{\"key\":\"value\"}", "key");
    ASSERT_STR_EQ(v, "value", "simple string");
    jenova_json_free(v);

    v = jenova_json_get("{\"a\":\"hello\",\"b\":\"world\"}", "b");
    ASSERT_STR_EQ(v, "world", "second key");
    jenova_json_free(v);
}

static void test_scalar_values(void) {
    printf("  scalar (non-string) values...\n");
    char *v;

    v = jenova_json_get("{\"n\":42}", "n");
    ASSERT_STR_EQ(v, "42", "integer");
    jenova_json_free(v);

    v = jenova_json_get("{\"f\":true}", "f");
    ASSERT_STR_EQ(v, "true", "boolean true");
    jenova_json_free(v);

    v = jenova_json_get("{\"f\":false}", "f");
    ASSERT_STR_EQ(v, "false", "boolean false");
    jenova_json_free(v);

    v = jenova_json_get("{\"n\":null}", "n");
    ASSERT_STR_EQ(v, "null", "null scalar");
    jenova_json_free(v);
}

/* Structural characters inside a top-level string value must not corrupt
 * the depth counter or cause premature termination.  This is the primary
 * bug identified in the review. */
static void test_structural_chars_in_string_value(void) {
    printf("  structural chars inside string values...\n");
    char *v;

    v = jenova_json_get("{\"a\":\"has {braces} inside\",\"b\":\"found\"}", "b");
    ASSERT_STR_EQ(v, "found", "braces in string value");
    jenova_json_free(v);

    v = jenova_json_get("{\"a\":\"has [brackets] inside\",\"b\":\"found\"}", "b");
    ASSERT_STR_EQ(v, "found", "brackets in string value");
    jenova_json_free(v);

    v = jenova_json_get("{\"a\":\"open { no close\",\"b\":\"found\"}", "b");
    ASSERT_STR_EQ(v, "found", "unmatched brace in string value");
    jenova_json_free(v);
}

/* Keys in nested objects must never match. */
static void test_nested_objects_not_matched(void) {
    printf("  nested objects with repeated keys...\n");
    char *v;

    v = jenova_json_get("{\"outer\":\"top\",\"nested\":{\"outer\":\"inner_val\"}}", "outer");
    ASSERT_STR_EQ(v, "top", "top-level wins over nested same-name key");
    jenova_json_free(v);

    /* The key only exists in a nested object — must not be found. */
    v = jenova_json_get("{\"nested\":{\"key\":\"deep\"}}", "key");
    ASSERT_NULL(v, "nested-only key not found at depth-1");

    /* Key in an array element must not match. */
    v = jenova_json_get("{\"arr\":[{\"key\":\"arr_val\"}]}", "key");
    ASSERT_NULL(v, "key inside array element not matched");
}

/* Trailing whitespace around scalar values must be stripped. */
static void test_scalar_trailing_whitespace(void) {
    printf("  scalar values with trailing whitespace...\n");
    char *v;

    v = jenova_json_get("{\"n\":  42  }", "n");
    ASSERT_STR_EQ(v, "42", "scalar leading/trailing whitespace stripped");
    jenova_json_free(v);
}

/* Malformed JSON must not crash and should return NULL safely. */
static void test_malformed_json(void) {
    printf("  malformed JSON safety...\n");
    char *v;

    v = jenova_json_get("not json at all", "key");
    ASSERT_NULL(v, "non-object input");

    v = jenova_json_get("{\"key\":}", "key");
    ASSERT_NULL(v, "missing value");

    v = jenova_json_get("{\"unterminated", "unterminated");
    ASSERT_NULL(v, "unterminated object");

    v = jenova_json_get("{\"key\":\"unterminated string}", "key");
    ASSERT_NULL(v, "unterminated string value");

    v = jenova_json_get(NULL, "key");
    ASSERT_NULL(v, "NULL json_str");

    v = jenova_json_get("{\"key\":\"val\"}", NULL);
    ASSERT_NULL(v, "NULL path");
}

/* Value that is itself an object or array — return it as raw text (not
 * currently spec-d for jenova_json_get, but must not crash). */
static void test_object_value_does_not_crash(void) {
    printf("  object/array values do not crash...\n");
    /* We only care that it doesn't crash; return value may be NULL or raw. */
    char *v = jenova_json_get("{\"obj\":{\"a\":1},\"after\":\"ok\"}", "after");
    ASSERT_STR_EQ(v, "ok", "key after nested-object value");
    jenova_json_free(v);

    v = jenova_json_get("{\"arr\":[1,2,3],\"after\":\"ok\"}", "after");
    ASSERT_STR_EQ(v, "ok", "key after array value");
    jenova_json_free(v);
}

int main(void) {
    printf("=== JSON Unit Tests ===\n");

    test_simple_string();
    test_scalar_values();
    test_structural_chars_in_string_value();
    test_nested_objects_not_matched();
    test_scalar_trailing_whitespace();
    test_malformed_json();
    test_object_value_does_not_crash();

    printf("\nResults: %d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
