#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
WSM="$REPO_ROOT/wsm/scripts/wsm"
MSR="$BIN_DIR/msr"
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

printf '=== wsm exact canonical + unique basename only ===\n'
set +e
EXACT_OUT="$("$WSM" --root="$TMP" attach shell 2>&1)"
EXACT_RC=$?
AMBIG="$("$WSM" --root="$TMP" attach api/shell 2>&1)"
AMBIG_RC=$?
NOMATCH="$("$WSM" --root="$TMP" attach pathdb/api 2>&1)"
NOMATCH_RC=$?
set -e
printf 'exact rc=%s out=[%s]\n' "$EXACT_RC" "$EXACT_OUT"
printf '%s\n' "$AMBIG" | sed -n '1,10p'
printf 'nomatch rc=%s out=[%s]\n' "$NOMATCH_RC" "$NOMATCH"
[[ $EXACT_RC -eq 0 ]]
[[ $AMBIG_RC -ne 0 ]]
printf '%s\n' "$AMBIG" | grep -q 'wsm: no match for query: api/shell'
[[ $NOMATCH_RC -ne 0 ]]
printf '%s\n' "$NOMATCH" | grep -q 'wsm: no match for query: pathdb/api'

printf '=== wsm status/exists/terminate ===\n'
STATUS_CTX_OUT="$(MSR_SESSION="$TMP/pathdb/api/build.msr" WSM_ROOT="$TMP" "$WSM" status 2>&1)"
EXISTS_CTX_OUT="$(MSR_SESSION="$TMP/pathdb/api/build.msr" WSM_ROOT="$TMP" "$WSM" exists 2>&1)"
printf 'status_ctx=[%s]\n' "$STATUS_CTX_OUT"
printf 'exists_ctx=[%s]\n' "$EXISTS_CTX_OUT"
[[ "$STATUS_CTX_OUT" == 'running' ]]
[[ "$EXISTS_CTX_OUT" == 'true' ]]
"$WSM" --root="$TMP" terminate pathdb/api/build TERM >/dev/null

printf '=== wsm local nav delegates to dsm ===\n'
set +e
NOCTX="$("$WSM" prev 2>&1)"
NOCTX_RC=$?
set -e
printf 'noctx rc=%s out=[%s]\n' "$NOCTX_RC" "$NOCTX"
[[ $NOCTX_RC -ne 0 ]]
printf '%s\n' "$NOCTX" | grep -q 'wsm: command requires current WSM session context'
set +e
PREV_FAIL_OUT="$(MSR_SESSION="$TMP/pathdb/api/build.msr" WSM_ROOT="$TMP" "$WSM" prev 2>&1)"
PREV_FAIL_RC=$?
set -e
printf 'prev-fail rc=%s out=[%s]\n' "$PREV_FAIL_RC" "$PREV_FAIL_OUT"
[[ $PREV_FAIL_RC -ne 0 ]]
printf '%s
' "$PREV_FAIL_OUT" | grep -q 'dsm: no previous session'
set +e
NEXT_FAIL_OUT="$(MSR_SESSION="$TMP/pathdb/api/shell.msr" WSM_ROOT="$TMP" "$WSM" next 2>&1)"
NEXT_FAIL_RC=$?
set -e
printf 'next-fail rc=%s out=[%s]\n' "$NEXT_FAIL_RC" "$NEXT_FAIL_OUT"
[[ $NEXT_FAIL_RC -ne 0 ]]
printf '%s
' "$NEXT_FAIL_OUT" | grep -q 'dsm: no next session'
set +e
PREV_OK_OUT="$(MSR_SESSION="$TMP/pathdb/api/shell.msr" WSM_ROOT="$TMP" "$WSM" prev 2>&1)"
PREV_OK_RC=$?
set -e
printf 'prev-ok rc=%s out=[%s]\n' "$PREV_OK_RC" "$PREV_OK_OUT"
[[ $PREV_OK_RC -eq 0 ]]

printf '=== wsm nested help ===\n'
set +e
HELP_OUT="$(MSR_SESSION="$TMP/pathdb/api/shell.msr" WSM_ROOT="$TMP" "$WSM" 2>&1)"
HELP_RC=$?
set -e
printf '%s\n' "$HELP_OUT" | sed -n '1,16p'
[[ $HELP_RC -ne 0 ]]
printf '%s\n' "$HELP_OUT" | grep -q 'NESTED MODE'
printf '%s\n' "$HELP_OUT" | grep -q 'workspace root: '
