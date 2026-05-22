#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
WSM_BIN="${WSM_BIN:-$BIN_DIR/wsm}"
HOST_BIN="${HOST_BIN:-$BIN_DIR/host}"
PTYLOG_BIN="${PTYLOG_BIN:-$BIN_DIR/ptylog}"
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
[[ -x "$PTYLOG_BIN" ]]

printf '=== wsm create detached ===\n'
CREATE_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d demo)"
printf '%s\n' "$CREATE_OUT"
printf '%s\n' "$CREATE_OUT" | grep -q '^created demo$'
[[ -S "$TMP/demo.wsm" || -f "$TMP/demo.wsm" ]]
[[ -S "$TMP/demo.ctl" || -f "$TMP/demo.ctl" ]]

printf '=== detached host is isolated from launcher process group ===\n'
HOST_PID="$(pgrep -f "$HOST_BIN $TMP/demo.ctl --headless -- $HOST_BIN $TMP/demo.wsm" | tail -n 1)"
[[ -n "$HOST_PID" ]]
LAUNCHER_PGID="$(ps -o pgid= -p "$$" | tr -d ' ')"
HOST_PGID="$(ps -o pgid= -p "$HOST_PID" | tr -d ' ')"
[[ -n "$LAUNCHER_PGID" ]]
[[ -n "$HOST_PGID" ]]
[[ "$HOST_PGID" != "$LAUNCHER_PGID" ]]
LAUNCHER_SID="$(ps -o sid= -p "$$" | tr -d ' ')"
HOST_SID="$(ps -o sid= -p "$HOST_PID" | tr -d ' ')"
[[ -n "$LAUNCHER_SID" ]]
[[ -n "$HOST_SID" ]]
[[ "$HOST_SID" != "$LAUNCHER_SID" ]]

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

printf '=== detached log prompt survives force kill ===\n'
CREATE2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d promptdemo)"
printf '%s\n' "$CREATE2_OUT"
printf '%s\n' "$CREATE2_OUT" | grep -q '^created promptdemo$'
sleep 1
KILL2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" kill -f promptdemo)"
printf '%s\n' "$KILL2_OUT"
printf '%s\n' "$KILL2_OUT" | grep -q '^signaled promptdemo (KILL)$'
[[ -f "$TMP/promptdemo.log" ]]
[[ -f "$TMP/promptdemo.typescript" ]]
grep -q '\$' "$TMP/promptdemo.log"
grep -q '\$' "$TMP/promptdemo.typescript"

printf '=== wsm cleanup report ===\n'
CLEANUP_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" cleanup)"
printf '%s\n' "$CLEANUP_OUT"
printf '%s\n' "$CLEANUP_OUT" | grep -q '^SESSION'

printf 'smoke ok\n'
