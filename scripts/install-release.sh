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

have_libvterm() {
  if need_cmd ldconfig && ldconfig -p 2>/dev/null | grep -q 'libvterm\.so\.0'; then
    return 0
  fi
  for p in \
    /lib/x86_64-linux-gnu/libvterm.so.0 \
    /usr/lib/x86_64-linux-gnu/libvterm.so.0 \
    /lib64/libvterm.so.0 \
    /usr/lib64/libvterm.so.0; do
    [ -e "$p" ] && return 0
  done
  return 1
}

install_runtime_deps_if_possible() {
  if have_libvterm; then
    return 0
  fi

  warn "install-release.sh: missing runtime dependency libvterm.so.0"
  if need_cmd apt-get; then
    warn "install-release.sh: on Debian/Ubuntu/WSL, run: sudo apt-get update && sudo apt-get install -y libvterm0"
  else
    warn "install-release.sh: install your distro's libvterm runtime package, then re-run this installer"
  fi
  exit 1
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

install_runtime_deps_if_possible

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
