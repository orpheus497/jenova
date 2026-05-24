#!/bin/sh
# tests/test_validate_arg.sh: Test suite for detect-hardware.sh argument validation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JENOVA_ROOT="$(dirname "$SCRIPT_DIR")"
DETECT_HW="$JENOVA_ROOT/hardware-profiles/detect-hardware.sh"

# Create isolated test environment for JENOVA_HOME to prevent modifying real configs
export JENOVA_HOME="$(mktemp -d)"
trap 'rm -rf "$JENOVA_HOME"' EXIT INT TERM

echo "Running detect-hardware.sh validation tests..."

# Helper to run detect-hardware.sh with args and assert failure
assert_fail() {
    _arg="$1"
    echo "Testing failure for arg: '$_arg'"
    _out=$("$DETECT_HW" --apply-profile "$_arg" 2>&1)
    _status=$?
    if [ "$_status" -eq 0 ]; then
        echo "FAIL: Expected failure for arg '$_arg', but it succeeded." >&2
        exit 1
    fi
    echo "OK: Failed as expected (Status: $_status). Output: $_out"
}

# Helper to run detect-hardware.sh with args and assert validation success
assert_pass() {
    _arg="$1"
    echo "Testing pass for arg: '$_arg'"
    _out=$("$DETECT_HW" --apply-profile "$_arg" 2>&1)
    _status=$?
    # Since the profile may or may not succeed in full application, we look at the validation error.
    # Validation errors output: "Invalid argument for..." or "Access denied" or similar.
    # If the output indicates the profile was not found or was applied, then the validation succeeded.
    if echo "$_out" | grep -qE "Invalid argument|Access denied|Option --apply-profile requires"; then
        echo "FAIL: Validation failed for valid arg '$_arg'. Output: $_out" >&2
        exit 1
    fi
    echo "OK: Validation passed for '$_arg'. Output: $_out"
}

# Test 1: Handle unexpected subsequent options (values starting with -)
assert_fail "--list"
assert_fail "-h"
assert_fail "--info"

# Test 2: Prevent path traversal (outside SCRIPT_DIR)
assert_fail "../../etc"
assert_fail "../bin"
assert_fail "/etc"
assert_fail "/etc/passwd"
assert_fail "/etc/../../etc/passwd"
assert_fail "Linux/Vulkan/dgpu/gtx-1650ti/../../../../etc/passwd"
assert_fail "/../etc"

# Test 3: Prevent dot/dot-dot directories (resolves to SCRIPT_DIR or parent, not a subdirectory)
assert_fail "."
assert_fail ".."

# Test 4: Verify valid profiles pass validation (though they might fail later if not existing, they should not trigger validation access denied/unexpected option error)
assert_pass "Linux/Vulkan/dgpu/gtx-1650ti"
assert_pass "nonexistent-profile-name" # This will fail with "Profile not found: nonexistent-profile-name" but it should PASS validation itself.

echo "All detect-hardware.sh validation tests passed."
exit 0
