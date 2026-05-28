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
  WSM_ROOT="$TMP" "$WSM_BIN" kill ui >/dev/null 2>&1 || true
  WSM_ROOT="$TMP" "$WSM_BIN" kill ui-base >/dev/null 2>&1 || true
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
printf 'hello from log\n' > "$TMP/demo.log"
LOG_OUT="$(WSM_ROOT="$TMP" WSM_LOGS_VIEWER_BIN="$LOG_VIEWER_SHIM" "$WSM_BIN" log demo)"
printf '%s\n' "$LOG_OUT"
printf '%s\n' "$LOG_OUT" | grep -q 'hello from log'

printf '=== wsm kill ===\n'
KILL_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" kill demo)"
printf '%s\n' "$KILL_OUT"
printf '%s\n' "$KILL_OUT" | grep -q '^signaled demo (TERM)$'

printf '=== detached force kill leaves a readable log without replay artifact ===\n'
CREATE2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d promptdemo)"
printf '%s\n' "$CREATE2_OUT"
printf '%s\n' "$CREATE2_OUT" | grep -q '^created promptdemo$'
sleep 1
KILL2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" kill -f promptdemo)"
printf '%s\n' "$KILL2_OUT"
printf '%s\n' "$KILL2_OUT" | grep -q '^signaled promptdemo (KILL)$'
[[ -f "$TMP/promptdemo.log" ]]
[[ ! -e "$TMP/promptdemo.typescript" ]]

printf '=== attached ctrl-c stays inside the session ===\n'
CREATE3_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d ctrldemo)"
printf '%s\n' "$CREATE3_OUT"
printf '%s\n' "$CREATE3_OUT" | grep -q '^created ctrldemo$'
tmux kill-session -t wsmsmokectrl 2>/dev/null || true
tmux new-session -d -s wsmsmokectrl "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach ctrldemo"
sleep 1
tmux has-session -t wsmsmokectrl
tmux send-keys -t wsmsmokectrl:0.0 C-c
sleep 1
ATTACH_CAPTURE="$(tmux capture-pane -pt wsmsmokectrl:0.0 || true)"
printf '%s\n' "$ATTACH_CAPTURE"
printf '%s\n' "$ATTACH_CAPTURE" | grep -q '\^C'
INSPECT2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" inspect ctrldemo)"
printf '%s\n' "$INSPECT2_OUT"
printf '%s\n' "$INSPECT2_OUT" | grep -Eq 'ctrldemo[[:space:]]+live'
tmux kill-session -t wsmsmokectrl 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f ctrldemo >/dev/null 2>&1 || true

printf '=== attached menu create attaches to the new session ===\n'
CREATE4_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" create -d ui-base)"
printf '%s\n' "$CREATE4_OUT"
printf '%s\n' "$CREATE4_OUT" | grep -q '^created ui-base$'
tmux kill-session -t wsmsmokecreate 2>/dev/null || true
tmux new-session -d -s wsmsmokecreate "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach ui-base"
sleep 1
tmux send-keys -t wsmsmokecreate:0.0 C-g
sleep 0.2
tmux send-keys -t wsmsmokecreate:0.0 c
sleep 0.2
tmux send-keys -t wsmsmokecreate:0.0 u
sleep 0.1
tmux send-keys -t wsmsmokecreate:0.0 i
sleep 0.2
tmux send-keys -t wsmsmokecreate:0.0 Enter
sleep 1
LIST2_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" list)"
printf '%s\n' "$LIST2_OUT"
printf '%s\n' "$LIST2_OUT" | grep -q '^ui$'
CAPTURE2="$(tmux capture-pane -pt wsmsmokecreate:0.0 || true)"
printf '%s\n' "$CAPTURE2"
printf '%s\n' "$CAPTURE2" | grep -q "$TMP/ui"
tmux kill-session -t wsmsmokecreate 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f ui >/dev/null 2>&1 || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f ui-base >/dev/null 2>&1 || true

printf '=== wsm cleanup report ===\n'
CLEANUP_OUT="$(WSM_ROOT="$TMP" "$WSM_BIN" cleanup)"
printf '%s\n' "$CLEANUP_OUT"
printf '%s\n' "$CLEANUP_OUT" | grep -q '^SESSION'

printf 'smoke ok\n'
