#!/bin/sh
# Script function and purpose: Contract test for the filesystem half of the API —
# the dimension tests/test_api_db.sh cannot see.
#
# test_api_db.sh passes 22/22 while asserting only over HTTP responses, so it had
# no assertion that could fail when src/jenova/api.nim omitted every fs_sync call
# lib/proxy.lua makes (N-27). A green suite says nothing about what it does not
# look at. This script looks at the disk.
#
# Every assertion encodes something lib/fs_sync.lua and lib/proxy.lua do:
# the physical path layout, the "<epoch>_<name>" trash naming, the
# .metadata.json sidecar, the rename-then-trash-the-old-path behaviour, and the
# four /api/fs/* routes. jca_web is frozen (D-Z) and reads these, so the standard
# is identical, not merely sensible.
#
# Usage: sh tests/test_api_fs.sh [port]
# Runs entirely inside a scratch JCA_HOME and removes it on exit. It must never
# touch a real deployment (ruling D-Y).

set -u

PORT=${1:-18721}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE="$ROOT/bin/jenova-core"
FAILED=0

[ -x "$CORE" ] || { echo "SKIP: $CORE not built (run: make core)"; exit 0; }
command -v nc >/dev/null 2>&1 || { echo "SKIP: nc not available"; exit 0; }

JCA_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jenova-apifs.XXXXXX") || exit 1
export JCA_HOME
mkdir -p "$JCA_HOME/.system" "$JCA_HOME/Workspaces"
WS="$JCA_HOME/Workspaces"

req() { # method path body
    printf '%s %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$1" "$2" "${#3}" "$3" | nc 127.0.0.1 "$PORT" | tail -1
}
get() {
    printf 'GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" | nc 127.0.0.1 "$PORT" | tail -1
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; shift; for l in "$@"; do echo "       $l"; done; FAILED=$((FAILED + 1)); }

assert_file() { # label path
    if [ -f "$2" ]; then pass "$1"; else fail "$1" "expected a file at: $2"; fi
}
assert_dir() { # label path
    if [ -d "$2" ]; then pass "$1"; else fail "$1" "expected a directory at: $2"; fi
}
assert_absent() { # label path
    if [ -e "$2" ]; then fail "$1" "expected nothing at: $2"; else pass "$1"; fi
}
assert_content() { # label path expected
    got=$(cat "$2" 2>/dev/null)
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "expected: $3" "got:      $got"; fi
}
assert_match() { # label pattern actual
    if printf '%s' "$3" | grep -q -- "$2"; then pass "$1"
    else fail "$1" "expected to match: $2" "got:               $3"; fi
}
# Exactly one entry matching a glob, echoed. Trash names carry an epoch prefix,
# so they cannot be predicted — they are found.
find_one() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | head -1; }

JENOVA_PORT="$PORT" "$CORE" serve >/dev/null 2>&1 &
SRV=$!
cleanup() {
    kill $SRV 2>/dev/null
    case "$JCA_HOME" in
        */jenova-apifs.*) rm -rf "$JCA_HOME" ;;
    esac
}
trap cleanup EXIT INT TERM
sleep 1

echo "test_api_fs: port $PORT  scratch $JCA_HOME"

# Action purpose: prove the server is actually reachable before asserting
# anything. Half of the checks below are absence checks, and an absence check
# passes vacuously when the whole system is unreachable — a first run of this
# script reported "ok" against a server listening on a different port because
# JENOVA_PORT had been omitted. A liveness gate is the cheapest defence against
# a suite that passes while measuring nothing.
if ! get /health | grep -q .; then
    echo "  FAIL server did not answer /health on port $PORT — aborting"
    echo "test_api_fs: FAIL (unreachable)"
    exit 1
fi

# Valid UUIDs are required: fs_sync.lua:70 refuses to mirror a row whose id is
# not one, so short ids like "w1" would silently mirror nothing.
WID="11111111-1111-1111-1111-111111111111"
PID="22222222-2222-2222-2222-222222222222"
FID="33333333-3333-3333-3333-333333333333"
NID="44444444-4444-4444-4444-444444444444"
AID="55555555-5555-5555-5555-555555555555"

# --- creates mirror onto disk ----------------------------------------------
req POST /api/db/workspaces "{\"id\":\"$WID\",\"name\":\"Alpha\"}" >/dev/null
assert_dir  "workspace create makes its directory"       "$WS/Alpha"
assert_dir  "workspace directory is a git repository"    "$WS/Alpha/.git"

req POST /api/db/projects "{\"id\":\"$PID\",\"workspaceId\":\"$WID\",\"name\":\"Beta\"}" >/dev/null
req POST /api/db/folders "{\"id\":\"$FID\",\"projectId\":\"$PID\",\"name\":\"Gamma\"}" >/dev/null

req POST /api/db/notes \
    "{\"id\":\"$NID\",\"folderId\":\"$FID\",\"title\":\"Hello\",\"content\":\"body text\"}" >/dev/null
assert_file    "note create writes its file"    "$WS/Alpha/Beta/Gamma/Hello_$NID.md"
assert_content "note file holds the content"    "$WS/Alpha/Beta/Gamma/Hello_$NID.md" "body text"

# A data: URI must be base64-decoded to bytes, not stored as its own encoding
# (fs_sync.lua:172). "aGVsbG8=" decodes to "hello".
req POST /api/db/fileAssets \
    "{\"id\":\"$AID\",\"folderId\":\"$FID\",\"name\":\"a.txt\",\"content\":\"data:text/plain;base64,aGVsbG8=\"}" >/dev/null
assert_file    "asset create writes its file"          "$WS/Alpha/Beta/Gamma/a.txt_$AID"
assert_content "asset data: URI is base64-decoded"     "$WS/Alpha/Beta/Gamma/a.txt_$AID" "hello"

# --- a rename moves the file and trashes the old path -----------------------
# proxy.lua:903 — on a title/parent change the new path is written and the OLD
# one is trashed. Without this a rename leaves both copies on disk.
req POST /api/db/notes \
    "{\"id\":\"$NID\",\"folderId\":\"$FID\",\"title\":\"Renamed\",\"content\":\"body text\"}" >/dev/null
assert_file   "rename writes the new path"        "$WS/Alpha/Beta/Gamma/Renamed_$NID.md"
assert_absent "rename removes the old path"       "$WS/Alpha/Beta/Gamma/Hello_$NID.md"

# --- /api/fs/tree -----------------------------------------------------------
assert_match "tree lists the note"        "Renamed_$NID.md" "$(get /api/fs/tree)"
assert_match "tree marks directories"     '"isDir":true'    "$(get /api/fs/tree)"
assert_match "tree scopes to a workspace" 'Beta'            "$(get '/api/fs/tree?workspace=Alpha')"
assert_match "tree rejects traversal"     '^\[\]'           "$(get '/api/fs/tree?workspace=../..')"

# --- delete moves to trash with a metadata sidecar --------------------------
req DELETE "/api/db/notes/$NID" '' >/dev/null
assert_absent "note delete removes the live file" "$WS/Alpha/Beta/Gamma/Renamed_$NID.md"
TRASHED=$(find_one "$WS/Alpha/.trash" "*_Renamed_$NID.md")
if [ -n "$TRASHED" ]; then pass "note delete moves the file to workspace trash"
else fail "note delete moves the file to workspace trash" "nothing matching *_Renamed_$NID.md in $WS/Alpha/.trash"; fi
assert_file "trashed note has a metadata sidecar" "$TRASHED.metadata.json"
if [ -n "$TRASHED" ]; then
    # The sidecar's FIELDS are the contract, not its byte layout. fs_sync.lua
    # writes '{"type": "notes", ...}' with spaces; the Nim core emits compact
    # JSON. Only these two components ever read the file and both parse it as
    # JSON, so the formats are interchangeable in either direction — an
    # assertion on the spacing would pin an incidental detail and fail a correct
    # implementation, which is what a first version of this check did.
    assert_match "sidecar records the table"         '"type": *"notes"' "$(cat "$TRASHED.metadata.json")"
    assert_match "sidecar records the row id"        "$NID"             "$(cat "$TRASHED.metadata.json")"
    assert_match "sidecar records the original path" 'Renamed_'         "$(cat "$TRASHED.metadata.json")"
fi

# --- /api/fs/trash lists it -------------------------------------------------
assert_match "trash listing includes the note" "Renamed_$NID.md"  "$(get /api/fs/trash)"
assert_match "trash listing names the workspace" '"workspace":"Alpha"' "$(get /api/fs/trash)"
assert_match "trash listing hides sidecars" '^\(.*\)$' "$(get /api/fs/trash)"
if get /api/fs/trash | grep -q 'metadata.json'; then
    fail "trash listing excludes .metadata.json sidecars" "a sidecar leaked into the listing"
else
    pass "trash listing excludes .metadata.json sidecars"
fi

# --- restore puts it back and un-deletes the row ----------------------------
req POST /api/fs/trash/restore \
    "{\"trash_path\":\"$TRASHED\",\"original_path\":\"$WS/Alpha/Beta/Gamma/Renamed_$NID.md\"}" >/dev/null
assert_file   "restore returns the file to its original path" "$WS/Alpha/Beta/Gamma/Renamed_$NID.md"
assert_absent "restore removes the sidecar"                   "$TRASHED.metadata.json"
assert_match  "restore un-deletes the database row" "\"id\":\"$NID\"" "$(get /api/db/notes/all)"

# Restore must refuse a path outside a trash directory — an addition over
# fs_sync.lua, which would have renamed anything the caller named.
req POST /api/fs/trash/restore \
    "{\"trash_path\":\"$WS/Alpha/Beta/Gamma/Renamed_$NID.md\",\"original_path\":\"$JCA_HOME/escaped\"}" >/dev/null
assert_absent "restore refuses a source outside the trash" "$JCA_HOME/escaped"

# --- project delete moves the directory -------------------------------------
req DELETE "/api/db/projects/$PID" '' >/dev/null
assert_absent "project delete removes the live directory" "$WS/Alpha/Beta"
PTRASH=$(find_one "$WS/Alpha/.trash" "*_Beta")
if [ -n "$PTRASH" ]; then pass "project delete moves the directory to trash"
else fail "project delete moves the directory to trash" "nothing matching *_Beta in $WS/Alpha/.trash"; fi

# --- workspace delete moves to the GLOBAL trash, not the workspace one ------
req DELETE "/api/db/workspaces/$WID" '' >/dev/null
assert_absent "workspace delete removes the live directory" "$WS/Alpha"
WTRASH=$(find_one "$JCA_HOME/.trash" "*_Alpha")
if [ -n "$WTRASH" ]; then pass "workspace delete moves the directory to the global trash"
else fail "workspace delete moves the directory to the global trash" "nothing matching *_Alpha in $JCA_HOME/.trash"; fi

# --- empty trash ------------------------------------------------------------
req DELETE /api/fs/trash/empty '' >/dev/null
assert_match "trash is empty after empty_trash" '^\[\]' "$(get /api/fs/trash)"

# --- import must NOT mirror -------------------------------------------------
# db.import_data writes rows only; a bulk import running a git add per row is
# what made the original slow, and the files arrive with the dump.
IWID="66666666-6666-6666-6666-666666666666"
req POST /api/db/import "{\"workspaces\":[{\"id\":\"$IWID\",\"name\":\"Imported\"}]}" >/dev/null
assert_match  "import inserts the row"            "\"id\":\"$IWID\"" "$(get /api/db/workspaces)"
assert_absent "import does not create a directory" "$WS/Imported"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test_api_fs: PASS"
    exit 0
fi
echo "test_api_fs: FAIL ($FAILED)"
exit 1
