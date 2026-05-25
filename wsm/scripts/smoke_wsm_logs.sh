#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
WSM_BIN="${WSM_BIN:-$BIN_DIR/wsm}"
TMP="$(mktemp -d)"

cleanup() {
  tmux kill-session -t wsm_edit_log 2>/dev/null || true
  tmux kill-session -t wsm_alt_log 2>/dev/null || true
  tmux kill-session -t wsm_burst_log 2>/dev/null || true
  WSM_ROOT="$TMP" "$WSM_BIN" kill burst >/dev/null 2>&1 || true
  WSM_ROOT="$TMP" "$WSM_BIN" kill alt >/dev/null 2>&1 || true
  WSM_ROOT="$TMP" "$WSM_BIN" kill edit >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

assert_contains() {
  local needle="$1"
  local path="$2"
  grep -Fq -- "$needle" "$path"
}

assert_not_contains() {
  local needle="$1"
  local path="$2"
  if grep -Fq -- "$needle" "$path"; then
    echo "unexpected content in $path: $needle" >&2
    return 1
  fi
}

printf '=== build outputs present ===\n'
[[ -x "$WSM_BIN" ]]

printf '=== detached edit transcript stays clean after force kill ===\n'
WSM_ROOT="$TMP" "$WSM_BIN" create -d edit
sleep 1
tmux kill-session -t wsm_edit_log 2>/dev/null || true
tmux new-session -d -s wsm_edit_log "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach edit"
sleep 1
tmux send-keys -t wsm_edit_log:0.0 "lsx" C-h Enter
tmux send-keys -t wsm_edit_log:0.0 "printf 'file.txt\\n'" Enter
sleep 1
tmux kill-session -t wsm_edit_log 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f edit >/dev/null
assert_contains '$ ls' "$TMP/edit.log"
assert_contains 'file.txt' "$TMP/edit.log"
assert_not_contains 'lsx' "$TMP/edit.log"

printf '=== detached attached-session ANSI output stays readable ===\n'
WSM_ROOT="$TMP" "$WSM_BIN" create -d alt
sleep 1
tmux kill-session -t wsm_alt_log 2>/dev/null || true
tmux new-session -d -s wsm_alt_log "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach alt"
sleep 1
tmux send-keys -t wsm_alt_log:0.0 "printf '\\033[31mred\\033[0m\\n'" Enter
tmux send-keys -t wsm_alt_log:0.0 "echo done" Enter
sleep 1
tmux kill-session -t wsm_alt_log 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f alt >/dev/null
assert_contains 'red' "$TMP/alt.log"
assert_contains 'done' "$TMP/alt.log"

printf '=== detached burst output leaves readable log after force kill ===\n'
WSM_ROOT="$TMP" "$WSM_BIN" create -d burst
sleep 1
tmux kill-session -t wsm_burst_log 2>/dev/null || true
tmux new-session -d -s wsm_burst_log "cd '$REPO_ROOT' && WSM_ROOT='$TMP' '$WSM_BIN' attach burst"
sleep 1
tmux send-keys -t wsm_burst_log:0.0 'for i in $(seq 0 49); do echo line-$i; done' Enter
sleep 1
tmux kill-session -t wsm_burst_log 2>/dev/null || true
WSM_ROOT="$TMP" "$WSM_BIN" kill -f burst >/dev/null
assert_contains 'line-0' "$TMP/burst.log"
assert_contains 'line-49' "$TMP/burst.log"
[[ ! -e "$TMP/burst.typescript" ]]

printf 'smoke wsm logs ok\n'
