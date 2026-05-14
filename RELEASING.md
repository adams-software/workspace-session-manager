# Releasing

Minimal local release flow.

## 1) Verify repo state

```bash
git status --short
zig build
zig build test
bash wsm/scripts/smoke_wsm.sh
./scripts/build_dist.sh
```

## 2) Do a fresh local install sanity check

```bash
TMP_PREFIX="$(mktemp -d)"
mkdir -p "$TMP_PREFIX/sessions"
PREFIX="$TMP_PREFIX" sh dist/linux-x86_64/install.sh
PATH="$TMP_PREFIX/bin:/usr/bin:/bin" WSM_ROOT="$TMP_PREFIX/sessions" wsm help
```

Expected install layout:

- `bin/wsm`
- `libexec/wsm/host`
- `libexec/wsm/vpty`
- `libexec/wsm/scroll`
- `libexec/wsm/wsm_logs_viewer`

## 3) Push main

```bash
git push origin main
```

## 4) Tag the release

Replace the tag name with the real version.

```bash
git tag -a v0.1.0-beta.N -m "v0.1.0-beta.N"
git push origin v0.1.0-beta.N
```
