#!/usr/bin/env bash
# Compatibility wrapper. Prefer: source shared/scripts/dev_env.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../shared/scripts/dev_env.sh" "$@"
