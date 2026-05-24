#!/bin/sh
# tests/test_linux_tune_regex.sh: Test suite for linux-tune.sh sed regex.

echo "Running linux-tune.sh sed regex tests..."

# Create a temporary file to mock sysctl.conf
CONF_FILE=$(mktemp)
trap 'rm -f "$CONF_FILE"' EXIT INT TERM

# Helper function to run the sed deletion command on mock config
run_sed_delete() {
    _key="$1"
    _safe_key=$(echo "$_key" | sed 's/\./\\./g')
    sed -i "/^[[:space:]]*${_safe_key}[[:space:]]*=/d" "$CONF_FILE"
}

# Test Case 1: Exact match with no spaces
cat <<EOF > "$CONF_FILE"
vm.swappiness=10
net.core.rmem_max=2500000
EOF
run_sed_delete "vm.swappiness"
if grep -q "vm.swappiness" "$CONF_FILE"; then
    echo "FAIL: exact match with no spaces was not deleted" >&2
    exit 1
fi
echo "OK: exact match with no spaces deleted successfully"

# Test Case 2: Spaces around equal operator
cat <<EOF > "$CONF_FILE"
vm.swappiness = 10
net.core.rmem_max=2500000
EOF
run_sed_delete "vm.swappiness"
if grep -q "vm.swappiness" "$CONF_FILE"; then
    echo "FAIL: spaces around equal operator were not handled" >&2
    exit 1
fi
echo "OK: spaces around equal operator handled successfully"

# Test Case 3: Leading space and multiple spaces around equal
cat <<EOF > "$CONF_FILE"
  vm.swappiness   =   10
net.core.rmem_max=2500000
EOF
run_sed_delete "vm.swappiness"
if grep -q "vm.swappiness" "$CONF_FILE"; then
    echo "FAIL: leading space or multiple spaces around equal were not handled" >&2
    exit 1
fi
echo "OK: leading and multiple spaces handled successfully"

# Test Case 4: Partial key match (should NOT delete similar keys)
cat <<EOF > "$CONF_FILE"
vm.swappiness_other=20
net.core.rmem_max=2500000
EOF
run_sed_delete "vm.swappiness"
if ! grep -q "vm.swappiness_other" "$CONF_FILE"; then
    echo "FAIL: vm.swappiness_other was deleted when deleting vm.swappiness" >&2
    exit 1
fi
echo "OK: partial key match protected successfully"

echo "All linux-tune.sh sed regex tests passed."
exit 0
