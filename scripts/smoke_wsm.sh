#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WSM="$ROOT/scripts/wsm"
MSR="$ROOT/zig-out/bin/msr"
TMP="$(mktemp -d)"
cleanup() {
  "$MSR" terminate "$TMP/shell.msr" >/dev/null 2>&1 || true
  "$MSR" terminate "$TMP/pathdb/api/shell.msr" >/dev/null 2>&1 || true
  "$MSR" terminate "$TMP/other/api/shell.msr" >/dev/null 2>&1 || true
  "$MSR" terminate "$TMP/pathdb/api/build.msr" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/pathdb/api" "$TMP/other/api"

printf '=== wsm create/list/current ===\n'
"$WSM" --root="$TMP" create shell -- /bin/sh -lc 'sleep 5'
"$WSM" --root="$TMP" create pathdb/api/shell -- /bin/sh -lc 'sleep 5'
"$WSM" --root="$TMP" create other/api/shell -- /bin/sh -lc 'sleep 5'
"$WSM" --root="$TMP" create pathdb/api/build -- /bin/sh -lc 'sleep 5'
LIST_OUTPUT="$($WSM --root="$TMP" list)"
printf '%s\n' "$LIST_OUTPUT"
printf '%s\n' "$LIST_OUTPUT" | grep -q '^shell$'
printf '%s\n' "$LIST_OUTPUT" | grep -q '^pathdb/api/shell$'
printf '%s\n' "$LIST_OUTPUT" | grep -q '^other/api/shell$'
printf '%s\n' "$LIST_OUTPUT" | grep -q '^pathdb/api/build$'
CURRENT_OUTPUT="$(MSR_SESSION="$TMP/pathdb/api/shell.msr" WSM_ROOT="$TMP" "$WSM" current)"
printf '%s\n' "$CURRENT_OUTPUT"
[[ "$CURRENT_OUTPUT" == 'pathdb/api/shell' ]]

printf '=== wsm exact canonical wins ===\n'
set +e
EXACT_OUT="$("$WSM" --root="$TMP" attach shell 2>&1)"
EXACT_RC=$?
set -e
printf 'rc=%s out=[%s]\n' "$EXACT_RC" "$EXACT_OUT"
[[ $EXACT_RC -eq 0 ]]

printf '=== wsm ambiguous suffix ===\n'
set +e
AMBIG="$($WSM --root="$TMP" attach api/shell 2>&1)"
AMBIG_RC=$?
set -e
printf '%s\n' "$AMBIG" | sed -n '1,10p'
[[ $AMBIG_RC -ne 0 ]]
printf '%s\n' "$AMBIG" | grep -q 'wsm: ambiguous query: api/shell'
printf '%s\n' "$AMBIG" | grep -q '^pathdb/api/shell$'
printf '%s\n' "$AMBIG" | grep -q '^other/api/shell$'

printf '=== wsm status/exists ===\n'
"$WSM" --root="$TMP" status pathdb/api/build
"$WSM" --root="$TMP" exists pathdb/api/build >/dev/null
STATUS_CTX_OUT="$(MSR_SESSION="$TMP/pathdb/api/build.msr" WSM_ROOT="$TMP" "$WSM" status 2>&1)"
EXISTS_CTX_OUT="$(MSR_SESSION="$TMP/pathdb/api/build.msr" WSM_ROOT="$TMP" "$WSM" exists 2>&1)"
printf 'status_ctx=[%s]\n' "$STATUS_CTX_OUT"
printf 'exists_ctx=[%s]\n' "$EXISTS_CTX_OUT"
[[ "$STATUS_CTX_OUT" == 'running' ]]
[[ "$EXISTS_CTX_OUT" == 'true' ]]

printf '=== wsm nested help ===\n'
set +e
HELP_OUT="$(MSR_SESSION="$TMP/pathdb/api/shell.msr" WSM_ROOT="$TMP" "$WSM" 2>&1)"
HELP_RC=$?
set -e
printf '%s\n' "$HELP_OUT" | sed -n '1,16p'
[[ $HELP_RC -ne 0 ]]
printf '%s\n' "$HELP_OUT" | grep -q 'NESTED MODE'
printf '%s\n' "$HELP_OUT" | grep -q 'workspace root: '
