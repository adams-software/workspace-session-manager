#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_NAME="${1:-linux-x86_64}"
DIST_ROOT="$REPO_ROOT/dist/$TARGET_NAME"
BIN_DIR="$DIST_ROOT/bin"
COMPLETIONS_DIR="$DIST_ROOT/completions"

rm -rf "$DIST_ROOT"
mkdir -p "$BIN_DIR" "$COMPLETIONS_DIR"

(
  cd "$REPO_ROOT"
  zig build
)

install -m 0755 "$REPO_ROOT/zig-out/bin/msr" "$BIN_DIR/msr"
install -m 0755 "$REPO_ROOT/zig-out/bin/vpty" "$BIN_DIR/vpty"
install -m 0755 "$REPO_ROOT/zig-out/bin/alt" "$BIN_DIR/alt"
install -m 0755 "$REPO_ROOT/dsm/scripts/dsm" "$BIN_DIR/dsm"
install -m 0755 "$REPO_ROOT/wsm/scripts/wsm" "$BIN_DIR/wsm"

install -m 0644 "$REPO_ROOT/dsm/scripts/dsm_completion.bash" "$COMPLETIONS_DIR/dsm.bash"
install -m 0644 "$REPO_ROOT/wsm/scripts/wsm_completion.bash" "$COMPLETIONS_DIR/wsm.bash"

cat > "$DIST_ROOT/install.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DEST="$PREFIX/bin"
COMP_DEST="$PREFIX/share/bash-completion/completions"

mkdir -p "$BIN_DEST" "$COMP_DEST"
install -m 0755 "$SCRIPT_DIR/bin/"* "$BIN_DEST/"
install -m 0644 "$SCRIPT_DIR/completions/"* "$COMP_DEST/"

echo "Installed commands to: $BIN_DEST"
echo "Installed bash completions to: $COMP_DEST"
echo "Make sure $BIN_DEST is on your PATH."
EOS
chmod +x "$DIST_ROOT/install.sh"

cat > "$DIST_ROOT/README.txt" <<'EOS'
msr distribution bundle

Contents:
- bin/: user-facing commands
- completions/: bash completions
- install.sh: simple installer (defaults to ~/.local)

Install:
  ./install.sh

Or manually copy files from bin/ into a directory on PATH.
EOS

tar -C "$REPO_ROOT/dist" -czf "$REPO_ROOT/dist/msr-$TARGET_NAME.tar.gz" "$TARGET_NAME"

echo "Built distribution at: $DIST_ROOT"
echo "Built tarball at: $REPO_ROOT/dist/msr-$TARGET_NAME.tar.gz"
