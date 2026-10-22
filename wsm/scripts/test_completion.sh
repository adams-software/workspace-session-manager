#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_uid=$$
default_root="/tmp/wsm-$test_uid"
custom_root=$(mktemp -d /tmp/wsm-completion-custom.XXXXXX)

cleanup() {
  rm -rf -- "$default_root" "$custom_root"
}
trap cleanup EXIT

[[ ! -e "$default_root" ]] || {
  printf 'completion test workspace already exists: %s\n' "$default_root" >&2
  exit 1
}
mkdir -p "$default_root/proj" "$custom_root"
touch "$default_root/alpha.wsm" "$default_root/alpine.wsm" \
  "$default_root/beta.wsm" "$default_root/proj/api.wsm" \
  "$default_root/proj/app.wsm" "$custom_root/custom.wsm"

# Keep the product default deterministic without writing into the real user's
# workspace. Bash functions take precedence over external commands.
id() {
  [[ "${1:-}" == -u ]] || return 1
  printf '%s\n' "$test_uid"
}

_init_completion() {
  words=("${COMP_WORDS[@]}")
  cword=$COMP_CWORD
  cur=${COMP_WORDS[$COMP_CWORD]}
  if (( COMP_CWORD > 0 )); then
    prev=${COMP_WORDS[$((COMP_CWORD - 1))]}
  else
    prev=""
  fi
}

# shellcheck source=wsm_completion.bash
source "$REPO_ROOT/wsm/scripts/wsm_completion.bash"

complete_for() {
  COMP_WORDS=("$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  COMPREPLY=()
  _wsm_complete
}

expect_candidates() {
  local expected=$1
  shift
  complete_for "$@"
  local actual
  actual=$(printf '%s\n' "${COMPREPLY[@]}")
  [[ "$actual" == "$expected" ]] || {
    printf 'completion mismatch for %q: expected %q, got %q\n' "$*" "$expected" "$actual" >&2
    return 1
  }
}

unset WSM_ROOT
expect_candidates $'alpha\nalpine' wsm a al
expect_candidates 'proj/' wsm attach p
expect_candidates $'proj/api\nproj/app' wsm attach proj/a
expect_candidates 'beta' wsm x b
expect_candidates 'custom' wsm --workspace "$custom_root" a c
expect_candidates 'custom' wsm "--workspace=$custom_root" a c

printf 'wsm completion: default, explicit, aliases, prefixes, and nested paths passed\n'
