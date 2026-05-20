#!/bin/sh
# Profile-specific installer wrapper

JENOVA_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
exec "$JENOVA_ROOT/install-jenova.sh" "$@"