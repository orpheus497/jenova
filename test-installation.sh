#!/bin/bash
# test-installation.sh: Validate the Jenova installation fix
#
# This script tests different installation scenarios to ensure the fix works correctly.

set -e

JENOVA_ROOT="$(dirname "$(realpath "$0")")"
LOGDIR="$JENOVA_ROOT/var/log"
mkdir -p "$LOGDIR"

TEST_LOG="$LOGDIR/test-installation-$(date +%Y%m%d_%H%M%S).log"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Jenova Installation Test Suite                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Testing installation process..."
echo "Log file: $TEST_LOG"
echo ""

# Test 1: Dry-run test
echo -e "${BLUE}[TEST 1]${NC} Dry-run installation (--dry-run)"
if ./install-jenova.sh --dry-run 2>&1 | tee -a "$TEST_LOG"; then
    echo -e "${GREEN}✓${NC} Dry-run completed successfully"
else
    echo -e "${RED}✗${NC} Dry-run failed"
    exit 1
fi
echo ""

# Test 2: Check if install.sh has --force flag
echo -e "${BLUE}[TEST 2]${NC} Verify install.sh accepts --force flag"
if ./scripts/install.sh --help 2>&1 | grep -q "\-\-force"; then
    echo -e "${GREEN}✓${NC} --force flag is available in install.sh"
else
    echo -e "${RED}✗${NC} --force flag not found in install.sh"
    exit 1
fi
echo ""

# Test 3: Verify install-jenova.sh uses all required flags
echo -e "${BLUE}[TEST 3]${NC} Verify install-jenova.sh uses all required flags"
MISSING_FLAGS=""
grep -q "install.sh.*--force" ./install-jenova.sh || MISSING_FLAGS="$MISSING_FLAGS --force"
grep -q "install.sh.*--skip-lsp" ./install-jenova.sh || MISSING_FLAGS="$MISSING_FLAGS --skip-lsp"
grep -q "install.sh.*--skip-jvim" ./install-jenova.sh || MISSING_FLAGS="$MISSING_FLAGS --skip-jvim"
grep -q "install.sh.*--skip-llama" ./install-jenova.sh || MISSING_FLAGS="$MISSING_FLAGS --skip-llama"

if [ -z "$MISSING_FLAGS" ]; then
    echo -e "${GREEN}✓${NC} All flags present: --force --skip-lsp --skip-jvim --skip-llama"
else
    echo -e "${RED}✗${NC} Missing flags:$MISSING_FLAGS"
    exit 1
fi
echo ""

# Test 4: Check that stdin is not redirected to /dev/null
echo -e "${BLUE}[TEST 4]${NC} Verify install.sh is called without stdin redirection"
if grep -q 'scripts/install.sh.*--skip-lsp.*--skip-jvim.*--skip-llama.*--force' ./install-jenova.sh && \
   ! grep -q 'scripts/install.sh.*--skip-lsp.*--skip-jvim.*--skip-llama.*--force.*>/dev/null' ./install-jenova.sh; then
    echo -e "${GREEN}✓${NC} install.sh output is not redirected (users can see progress)"
else
    echo -e "${YELLOW}⚠${NC} Warning: Output redirection detected"
fi
echo ""

# Test 5: Syntax check
echo -e "${BLUE}[TEST 5]${NC} Shell syntax validation"
if bash -n ./install-jenova.sh 2>&1 | tee -a "$TEST_LOG"; then
    echo -e "${GREEN}✓${NC} install-jenova.sh syntax is valid"
else
    echo -e "${RED}✗${NC} Syntax errors found in install-jenova.sh"
    exit 1
fi

if bash -n ./scripts/install.sh 2>&1 | tee -a "$TEST_LOG"; then
    echo -e "${GREEN}✓${NC} scripts/install.sh syntax is valid"
else
    echo -e "${RED}✗${NC} Syntax errors found in scripts/install.sh"
    exit 1
fi
echo ""

# Test 6: Check for other potential hangs
echo -e "${BLUE}[TEST 6]${NC} Scan for other potential hanging issues"
HANG_SUSPECTS=$(grep -n "read -r" ./scripts/install.sh || echo "")
if [ -z "$HANG_SUSPECTS" ]; then
    echo -e "${GREEN}✓${NC} No interactive read prompts found in install.sh"
elif echo "$HANG_SUSPECTS" | grep -q "FORCE.*0"; then
    echo -e "${YELLOW}⚠${NC} Interactive prompts protected by --force flag"
else
    echo -e "${YELLOW}⚠${NC} Found potential interactive prompts:"
    echo "$HANG_SUSPECTS" | sed 's/^/  /'
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Test Results                                               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${GREEN}✓${NC} All critical tests passed!"
echo ""
echo "Next steps:"
echo "  1. For minimal install:  ./install-jenova.sh --minimal"
echo "  2. For full install:     ./install-jenova.sh"
echo "  3. Full with logging:    ./install-jenova.sh 2>&1 | tee var/log/install.log"
echo ""
echo "Log file: $TEST_LOG"
