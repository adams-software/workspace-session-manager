#!/usr/bin/env bash

# Source this file to expose repo-local msr/dsm/wsm entrypoints in your shell
# without making permanent changes.
#
# Usage:
#   source scripts/dev_env.sh
#
# Optional:
#   export MSR_REPO_ROOT=/absolute/path/to/repo
#   source scripts/dev_env.sh --build   # build msr first if zig-out/bin/msr is missing
#
# This script resolves its real location, so sourcing through a symlink works.
# If you copy it elsewhere, set MSR_REPO_ROOT first so it can find the repo.

resolve_source_path() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd -- "$(dirname -- "$src")" && pwd)"
    src="$(readlink -- "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -- "$(dirname -- "$src")" && pwd
}

SCRIPT_DIR="$(resolve_source_path)"
REPO_DIR="${MSR_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
BIN_DIR="$REPO_DIR/zig-out/bin"
SCRIPTS_DIR="$REPO_DIR/scripts"

if [[ "${1-}" == "--build" ]]; then
  (cd "$REPO_DIR" && zig build)
fi

if [[ ! -x "$BIN_DIR/msr" ]]; then
  echo "warning: $BIN_DIR/msr is missing or not executable" >&2
  echo "run: (cd '$REPO_DIR' && zig build)" >&2
fi

path_prepend() {
  local dir="$1"
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

path_prepend "$BIN_DIR"
path_prepend "$SCRIPTS_DIR"
export PATH
export MSR_REPO_DIR="$REPO_DIR"
export MSR_REPO_ROOT="$REPO_DIR"

# Best-effort bash completions.
if [[ -n "${BASH_VERSION-}" ]]; then
  if [[ -r "$SCRIPTS_DIR/dsm_completion.bash" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/dsm_completion.bash"
  fi
  if [[ -r "$SCRIPTS_DIR/wsm_completion.bash" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPTS_DIR/wsm_completion.bash"
  fi
fi

cat <<EOF
Loaded repo-local MSR dev environment.

Repo:    $REPO_DIR
PATH+:   $BIN_DIR
         $SCRIPTS_DIR

Commands now resolved from this repo:
- msr
- dsm
- wsm

Bash completions loaded if available for:
- dsm
- wsm

This shell only; no permanent changes were made.
EOF
