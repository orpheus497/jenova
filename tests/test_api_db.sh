#!/bin/sh
# Script function and purpose: Contract test for the Nim core's /api/db/* routes.
#
# These routes replace lib/proxy.lua's database handlers and must stay
# behaviour-compatible with them, because jca_web is a shipped client that has to
# keep working unchanged while it is deprecated (ruling D-L). Every assertion
# below encodes something proxy.lua does, not something that merely seems
# reasonable — in particular the fork reparenting, the recursive fork delete and
# the upward restore cascade, all three of which a first implementation missed.
#
# Usage: sh tests/test_api_db.sh [port]
# Starts its own jenova-core on a scratch database and stops it on exit.

set -u

PORT=${1:-18719}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE="$ROOT/bin/jenova-core"
FAILED=0

[ -x "$CORE" ] || { echo "SKIP: $CORE not built (run: make core)"; exit 0; }
command -v nc >/dev/null 2>&1 || { echo "SKIP: nc not available"; exit 0; }

# Action purpose: run entirely inside a scratch JCA_HOME, and never touch the
# real one. This script previously derived the database path as
# "${JCA_HOME:-$HOME/JCA}/.system/jenova.db" and rm'd it — so on any machine with
# a live deployment, running the suite DELETED THE USER'S CONVERSATION DATABASE.
# That is the B-22 defect class with real data at stake. The isolation below is
# the fix: every path the core resolves derives from JCA_HOME (see
# src/jenova/paths.nim), so overriding it here contains the whole test.
JCA_HOME=$(mktemp -d "${TMPDIR:-/tmp}/jenova-apidb.XXXXXX") || exit 1
export JCA_HOME
mkdir -p "$JCA_HOME/.system" "$JCA_HOME/Workspaces"
DB="$JCA_HOME/.system/jenova.db"

req() { # method path body
    printf '%s %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$1" "$2" "${#3}" "$3" | nc 127.0.0.1 "$PORT" | tail -1
}
get() {
    printf 'GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' "$1" | nc 127.0.0.1 "$PORT" | tail -1
}

check() { # label expected-substring actual
    if printf '%s' "$3" | grep -q -- "$2"; then
        echo "  ok   $1"
    else
        echo "  FAIL $1"
        echo "       expected to contain: $2"
        echo "       got:                 $3"
        FAILED=$((FAILED + 1))
    fi
}

check_absent() { # label unwanted-substring actual
    if printf '%s' "$3" | grep -q -- "$2"; then
        echo "  FAIL $1"
        echo "       expected NOT to contain: $2"
        echo "       got:                     $3"
        FAILED=$((FAILED + 1))
    else
        echo "  ok   $1"
    fi
}

rm -f "$DB" "$DB-wal" "$DB-shm"
JENOVA_NO_BACKENDS=1 JENOVA_PORT="$PORT" "$CORE" serve >/dev/null 2>&1 &
SRV=$!
# The scratch tree is removed on exit; the guard is belt-and-braces against the
# mktemp having failed and JCA_HOME pointing somewhere real.
cleanup() {
    kill $SRV 2>/dev/null
    case "$JCA_HOME" in
        */jenova-apidb.*) rm -rf "$JCA_HOME" ;;
    esac
}
trap cleanup EXIT INT TERM
sleep 1

echo "test_api_db: port $PORT"

# --- CRUD and typed columns ------------------------------------------------
req POST /api/db/workspaces '{"id":"w1","name":"Work"}' >/dev/null
req POST /api/db/projects '{"id":"p1","workspaceId":"w1","name":"Proj"}' >/dev/null
req POST /api/db/conversations '{"id":"c1","name":"Chat","lastModified":1730000000,"workspaceId":"w1"}' >/dev/null
req POST /api/db/messages '{"id":"m1","convId":"c1","role":"user","content":"hello","timestamp":1730000001}' >/dev/null

check "workspace round-trips"      '"id":"w1"'            "$(get /api/db/workspaces)"
check "project filtered by parent" '"id":"p1"'            "$(get '/api/db/projects?workspaceId=w1')"
check "integer column stays JSON number" '"timestamp":1730000001' "$(get '/api/db/messages?convId=c1')"
check "single message by id"       '"content":"hello"'    "$(get '/api/db/message?id=m1')"

# --- partial update --------------------------------------------------------
req POST /api/db/messages/update '{"id":"m1","content":"edited"}' >/dev/null
check "partial update writes only given fields" '"content":"edited"' "$(get '/api/db/message?id=m1')"
check "partial update preserves others"         '"role":"user"'      "$(get '/api/db/message?id=m1')"

# --- soft delete, trash, restore -------------------------------------------
req DELETE /api/db/conversations/c1 '' >/dev/null
check "deleted conversation leaves list" '^\[\]'      "$(get /api/db/conversations)"
check "messages cascade on delete"       '^\[\]'      "$(get '/api/db/messages?convId=c1')"
check "deleted conversation in trash"    '"id":"c1"'  "$(get /api/db/conversations/deleted)"
req POST /api/db/conversations/c1/restore '' >/dev/null
check "restore returns conversation"     '"id":"c1"'  "$(get /api/db/conversations)"
check "restore revives its messages"     '"id":"m1"'  "$(get '/api/db/messages?convId=c1')"

# --- fork tree: reparenting and recursive delete ----------------------------
# proxy.lua reparents children onto the deleted node's own parent, and deletes
# forks recursively rather than one level deep.
req POST /api/db/conversations '{"id":"root","name":"root"}' >/dev/null
req POST /api/db/conversations '{"id":"child","name":"child","forkedFromConversationId":"root"}' >/dev/null
req POST /api/db/conversations '{"id":"grand","name":"grand","forkedFromConversationId":"child"}' >/dev/null
req DELETE /api/db/conversations/child '' >/dev/null
check "child deleted without forks reparents grandchild" \
      '"forkedFromConversationId":"root"' "$(get '/api/db/conversations?id=grand')"
req DELETE '/api/db/conversations/root?deleteWithForks=true' '' >/dev/null
check "deleteWithForks removes nested descendants" \
      'null\|^\[\]\|not found' "$(get '/api/db/conversations?id=grand')"

# --- restore cascades upward to ancestors ----------------------------------
# The note id must be a real UUID. fs_sync.lua:70 refuses to mirror a row whose
# id is not one, and proxy.lua:899 then deletes the row and answers 500 — so a
# short id like "n2" is rejected by the real system. This assertion passed
# before the filesystem mirror existed (N-27) precisely because nothing checked.
N2="99999999-9999-9999-9999-999999999999"
req POST /api/db/workspaces '{"id":"w2","name":"W"}' >/dev/null
req POST /api/db/projects '{"id":"p2","workspaceId":"w2","name":"P"}' >/dev/null
req POST /api/db/notes "{\"id\":\"$N2\",\"projectId\":\"p2\",\"workspaceId\":\"w2\",\"title\":\"T\",\"content\":\"C\"}" >/dev/null
req DELETE /api/db/workspaces/w2 '' >/dev/null
# Scoped to p2: other workspaces' projects are still live, so an empty-list
# assertion here would be wrong rather than strict.
check_absent "workspace delete cascades to its project" '"id":"p2"' "$(get /api/db/projects/all)"
check "note with a non-UUID id is rejected" 'filesystem sync failed' \
      "$(req POST /api/db/notes '{"id":"n-short","projectId":"p2","title":"T"}')"
req POST "/api/db/notes/$N2/restore" '' >/dev/null
check "restoring a note revives its workspace" '"id":"w2"' "$(get /api/db/workspaces)"
check "restoring a note revives its project"   '"id":"p2"' "$(get /api/db/projects/all)"

# --- cache and import ------------------------------------------------------
req POST /api/db/cache '{"key":"k1","response":"cached"}' >/dev/null
check "cache round-trips"  '"response":"cached"' "$(get '/api/db/cache?key=k1')"
check "cache miss is 404"  'not found'           "$(get '/api/db/cache?key=absent')"
req POST /api/db/import '{"workspaces":[{"id":"w9","name":"Imported"}]}' >/dev/null
check "import inserts rows" '"id":"w9"' "$(get /api/db/workspaces)"

# --- error handling --------------------------------------------------------
check "unknown collection" 'unknown collection' "$(get /api/db/nope)"
check "invalid JSON body"  'invalid JSON'       "$(req POST /api/db/workspaces 'not json')"
check "object without id"  'id'                 "$(req POST /api/db/workspaces '{"name":"x"}')"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test_api_db: PASS"
    exit 0
fi
echo "test_api_db: FAIL ($FAILED)"
exit 1
