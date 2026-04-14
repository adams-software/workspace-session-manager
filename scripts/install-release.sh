#!/bin/sh
set -eu

REPO_SLUG=${REPO_SLUG:-adams-software/workspace-session-manager}
VERSION=${VERSION:-latest}
ASSET_NAME=${ASSET_NAME:-workspace-session-manager-linux-x86_64.tar.gz}

TMPDIR_BASE=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMPDIR_BASE/wsm-install.XXXXXX")
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

note() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}


case "$VERSION" in
  latest)
    URL="https://github.com/$REPO_SLUG/releases/latest/download/$ASSET_NAME"
    ;;
  *)
    URL="https://github.com/$REPO_SLUG/releases/download/$VERSION/$ASSET_NAME"
    ;;
esac

ARCHIVE="$WORKDIR/$ASSET_NAME"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$ARCHIVE" "$URL"
else
  echo "install-release.sh: need curl or wget" >&2
  exit 1
fi

mkdir -p "$WORKDIR/unpack"
tar -xzf "$ARCHIVE" -C "$WORKDIR/unpack"
cd "$WORKDIR/unpack/linux-x86_64"
sh ./install.sh
