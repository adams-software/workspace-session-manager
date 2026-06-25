#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
BIN_DIR="${MSR_BIN_DIR:-$REPO_ROOT/zig-out/bin}"
PTYLOG_BIN="${PTYLOG_BIN:-$BIN_DIR/ptylog}"
TMP="$(mktemp -d)"

cleanup() {
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

run_case() {
  local name="$1"
  shift
  local log_path="$TMP/$name.log"
  "$PTYLOG_BIN" --log "$log_path" -- "$@"
  echo "case=$name"
  cat "$log_path"
  echo
  echo "---"
}

printf '=== build outputs present ===\n'
[[ -x "$PTYLOG_BIN" ]]

printf '=== clean exit keeps committed output and final prompt ===\n'
run_case clean-exit /bin/bash -lc 'printf "alpha\r\n$ "'
assert_contains 'alpha' "$TMP/clean-exit.log"
assert_contains '$' "$TMP/clean-exit.log"

printf '=== alt screen body stays suppressed ===\n'
run_case alt-screen /bin/bash -lc 'printf "$ nvim foo.txt\r\n"; printf "\033[?1049h[editor noise]"; printf "\033[?1049l$ echo done\r\ndone\r\n$ "'
assert_contains '$ nvim foo.txt' "$TMP/alt-screen.log"
assert_contains 'done' "$TMP/alt-screen.log"
assert_not_contains '[editor noise]' "$TMP/alt-screen.log"

printf '=== term keeps latest tail when ptylog owns the graceful boundary ===\n'
TERM_LOG="$TMP/term.log"
"$PTYLOG_BIN" --log "$TERM_LOG" -- /bin/bash -lc 'printf "term-path\r\n$ "; sleep 5' &
PTYLOG_PID=$!
sleep 1
kill -TERM "$PTYLOG_PID"
wait "$PTYLOG_PID" || true
cat "$TERM_LOG"
assert_contains 'term-path' "$TERM_LOG"
assert_contains '$' "$TERM_LOG"

printf '=== kill may lose latest tail but log stays readable ===\n'
KILL_LOG="$TMP/kill.log"
"$PTYLOG_BIN" --log "$KILL_LOG" -- /bin/bash -lc 'printf "kill-path\r\n$ "; sleep 5' &
PTYLOG_KILL_PID=$!
sleep 1
kill -KILL "$PTYLOG_KILL_PID" || true
if wait "$PTYLOG_KILL_PID"; then
  :
else
  status=$?
  if [[ "$status" -ne 137 ]]; then
    exit "$status"
  fi
fi
[[ -f "$KILL_LOG" ]]
assert_contains 'kill-path' "$KILL_LOG"

printf '=== segmented logs keep a bounded recent window ===\n'
SEGMENT_LOG="$TMP/segmented.log"
"$PTYLOG_BIN" \
  --log "$SEGMENT_LOG" \
  --segment 128 \
  --keep 2 \
  -- /bin/bash -lc 'for i in $(seq 0 199); do printf "line-%03d\r\n" "$i"; done; printf "$ "' >/dev/null
[[ -f "$SEGMENT_LOG" ]]
compgen -G "$TMP/segmented.log.0*" >/dev/null
COMBINED_SEGMENT_LOG="$TMP/segmented.combined"
cat "$TMP"/segmented.log.0* "$SEGMENT_LOG" > "$COMBINED_SEGMENT_LOG"
assert_contains 'line-199' "$COMBINED_SEGMENT_LOG"
assert_not_contains 'line-000' "$COMBINED_SEGMENT_LOG"

printf 'stress ptylog ok\n'
