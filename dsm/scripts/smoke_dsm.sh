#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
DSM="$REPO_ROOT/dsm/scripts/dsm"
MSR="$BIN_DIR/msr"
TMP="$(mktemp -d)"
cleanup() {
  "$MSR" terminate "$TMP/alpha.msr" >/dev/null 2>&1 || true
  "$MSR" terminate "$TMP/beta.msr" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

printf '=== dsm create alias + ls ===\n'
"$DSM" --cwd="$TMP" c alpha -- /bin/sh -lc 'sleep 5'
LIST_OUTPUT="$($DSM --cwd "$TMP" ls)"
printf '%s\n' "$LIST_OUTPUT"
[[ "$LIST_OUTPUT" == "alpha" ]]

printf '=== dsm status/current/help ===\n'
"$DSM" --cwd="$TMP" status alpha
CURRENT_OUTPUT="$(MSR_SESSION="$TMP/alpha.msr" "$DSM" --cwd "$TMP" current)"
printf '%s\n' "$CURRENT_OUTPUT"
[[ "$CURRENT_OUTPUT" == "alpha" ]]
set +e
HELP_FILE="$TMP/help.out"
MSR_SESSION="$TMP/alpha.msr" "$DSM" --cwd="$TMP" >"$HELP_FILE" 2>&1
HELP_RC=$?
set -e
sed -n '1,12p' "$HELP_FILE"
[[ $HELP_RC -ne 0 ]]
grep -q 'NESTED MODE' "$HELP_FILE"
grep -q 'current session: ' "$HELP_FILE"

printf '=== dsm create second session + exists ===\n'
"$DSM" --cwd="$TMP" create beta -- /bin/sh -lc 'sleep 5'
"$DSM" --cwd="$TMP" exists beta >/dev/null
printf 'beta exists\n'
