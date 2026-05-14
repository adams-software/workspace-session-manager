#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
WSM_BIN="${WSM_BIN:-$BIN_DIR/wsm}"
HOST_BIN="${HOST_BIN:-$BIN_DIR/host}"
TMP="$(mktemp -d)"
LOG_VIEWER_SHIM="$TMP/log_viewer.sh"

cleanup() {
  WSM_ROOT="$TMP" "$WSM_BIN" kill demo >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

printf '=== build outputs present ===\n'
[[ -x "$WSM_BIN" ]]
[[ -x "$HOST_BIN" ]]

printf '=== wsm create detached ===\n'
CREATE_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d demo)"
printf '%s\n' "$CREATE_OUT"
printf '%s\n' "$CREATE_OUT" | grep -q '^created demo$'
[[ -S "$TMP/demo.wsm" || -f "$TMP/demo.wsm" ]]
[[ -S "$TMP/demo.ctl" || -f "$TMP/demo.ctl" ]]

printf '=== wsm list ===\n'
LIST_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" list)"
printf '%s\n' "$LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep -q '^demo$'

printf '=== wsm inspect ===\n'
INSPECT_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" inspect demo)"
printf '%s\n' "$INSPECT_OUT"
printf '%s\n' "$INSPECT_OUT" | grep -q '^SESSION'
printf '%s\n' "$INSPECT_OUT" | grep -q 'demo'
printf '%s\n' "$INSPECT_OUT" | grep -Eq 'live|stale_control_socket'

printf '=== wsm log ===\n'
cat > "$LOG_VIEWER_SHIM" <<'EOS'
#!/bin/sh
cat "$1"
EOS
chmod +x "$LOG_VIEWER_SHIM"
printf 'hello from transcript\n' > "$TMP/demo.typescript"
LOG_OUT="$(WSM_ROOT="$TMP" WSM_LOGS_VIEWER_BIN="$LOG_VIEWER_SHIM" "$WSM_BIN" log demo)"
printf '%s\n' "$LOG_OUT"
printf '%s\n' "$LOG_OUT" | grep -q 'hello from transcript'

printf '=== wsm kill ===\n'
KILL_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" kill demo)"
printf '%s\n' "$KILL_OUT"
printf '%s\n' "$KILL_OUT" | grep -q '^signaled demo (TERM)$'

printf '=== wsm cleanup report ===\n'
CLEANUP_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" cleanup)"
printf '%s\n' "$CLEANUP_OUT"
printf '%s\n' "$CLEANUP_OUT" | grep -q '^SESSION'

printf 'smoke ok\n'
