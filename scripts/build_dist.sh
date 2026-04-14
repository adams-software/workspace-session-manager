#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_NAME="${1:-linux-x86_64}"
DIST_ROOT="$REPO_ROOT/dist/$TARGET_NAME"
BIN_DIR="$DIST_ROOT/bin"
COMPLETIONS_DIR="$DIST_ROOT/completions"
TARBALL="$REPO_ROOT/dist/workspace-session-manager-$TARGET_NAME.tar.gz"
LEGACY_TARBALL="$REPO_ROOT/dist/msr-$TARGET_NAME.tar.gz"

rm -rf "$DIST_ROOT"
rm -f "$TARBALL" "$LEGACY_TARBALL"
mkdir -p "$BIN_DIR" "$COMPLETIONS_DIR"

(
  cd "$REPO_ROOT"
  zig build
)

install -m 0755 "$REPO_ROOT/zig-out/bin/msr" "$BIN_DIR/msr"
install -m 0755 "$REPO_ROOT/zig-out/bin/vpty" "$BIN_DIR/vpty"
install -m 0755 "$REPO_ROOT/zig-out/bin/alt" "$BIN_DIR/alt"
install -m 0755 "$REPO_ROOT/wsm/scripts/wsm" "$BIN_DIR/wsm"
install -m 0755 "$REPO_ROOT/wsm/scripts/wsm_menu" "$BIN_DIR/wsm_menu"

install -m 0644 "$REPO_ROOT/wsm/scripts/wsm_completion.bash" "$COMPLETIONS_DIR/wsm"

cat > "$DIST_ROOT/install.sh" <<'EOS'
#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
BIN_DEST=$PREFIX/bin
COMP_DEST=$PREFIX/share/bash-completion/completions
mkdir -p "$BIN_DEST" "$COMP_DEST"
install -m 0755 "$SCRIPT_DIR/bin/"* "$BIN_DEST/"
install -m 0644 "$SCRIPT_DIR/completions/"* "$COMP_DEST/"

echo "Installed commands to: $BIN_DEST"
echo "Installed bash completions to: $COMP_DEST"
echo "Bash completion files were installed as command-name autoload files."
echo "Make sure $BIN_DEST is on your PATH."
EOS
chmod +x "$DIST_ROOT/install.sh"

cat > "$DIST_ROOT/README.txt" <<'EOS'
workspace-session-manager distribution bundle

Contents:
- bin/: user-facing commands
- completions/: bash completion autoload files
- install.sh: POSIX sh installer (defaults to ~/.local)
- vendored libvterm is compiled into `vpty`; no separate system libvterm runtime package is required

Install:
  sh install.sh

Default install paths:
- commands -> ~/.local/bin
- completions -> ~/.local/share/bash-completion/completions

Or manually copy files from bin/ into a directory on PATH.
EOS

tar -C "$REPO_ROOT/dist" -czf "$TARBALL" "$TARGET_NAME"

echo "Built distribution at: $DIST_ROOT"
echo "Built tarball at: $TARBALL"
