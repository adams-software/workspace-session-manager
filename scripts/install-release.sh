#!/bin/sh
set -eu

REPO_SLUG=${REPO_SLUG:-adams-software/workspace-session-manager}
VERSION=${VERSION:-latest}
ASSET_NAME=${ASSET_NAME:-workspace-session-manager-linux-x86_64.tar.gz}

die() {
  echo "install-release.sh: $*" >&2
  exit 1
}

for cmd in uname mktemp mkdir rm tar gzip install env id getconf; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
[ "$(uname -s)" = Linux ] || die "release bundles support Linux only"
[ "$(uname -m)" = x86_64 ] || die "release bundles support x86_64 only"
[ -e /lib64/ld-linux-x86-64.so.2 ] || die "requires glibc Linux (glibc 2.28 or newer); musl/Alpine is not supported by this bundle"
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || die "cannot determine glibc version (need 2.28 or newer)"
glibc_version=${glibc#glibc }
glibc_major=${glibc_version%%.*}
glibc_minor=${glibc_version#*.}
glibc_minor=${glibc_minor%%.*}
case "$glibc_major:$glibc_minor" in
  *[!0-9:]*|:*|*:) die "unrecognized glibc version: $glibc" ;;
esac
if [ "$glibc_major" -lt 2 ] || { [ "$glibc_major" -eq 2 ] && [ "$glibc_minor" -lt 28 ]; }; then
  die "requires glibc 2.28 or newer; found $glibc_version"
fi

TMPDIR_BASE=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMPDIR_BASE/wsm-install.XXXXXX")
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

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

PREFIX=${PREFIX:-$HOME/.local}
printf '\nNext, make the command available in your current shell:\n'
printf '  export PATH="%s/bin:$PATH"\n' "$PREFIX"
printf '  wsm help\n'
printf '  wsm create test\n'
printf '\nAdd the PATH export to ~/.bashrc (Bash) or ~/.zshrc (Zsh) if needed.\n'
printf 'The installer cannot change its parent shell environment.\n'
printf '\nSession directory: wsm help shows WORKSPACE and the build default.\n'
printf 'To choose a persistent location, run:\n'
printf '  mkdir -p "$HOME/sessions"\n'
printf '  export WSM_ROOT="$HOME/sessions"\n'
printf 'Add that export to your shell startup file to keep the setting.\n'
printf 'Older releases without a WORKSPACE in help require this setup first.\n'
if ! command -v bash >/dev/null 2>&1 || ! command -v less >/dev/null 2>&1; then
  printf '\nFor wsm log, install Bash and less using your system package manager.\n'
fi
