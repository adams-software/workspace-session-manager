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

`build_dist.sh` now pins the release artifact to a portable Zig target for `linux-x86_64` instead of inheriting the release machine's native CPU features. That matters: a native build on a newer host can emit AVX instructions and crash with `Illegal instruction` on older x86_64 machines.

## 2) Do a fresh local install sanity check

```bash
TMP_PREFIX="$(mktemp -d)"
mkdir -p "$TMP_PREFIX/sessions"
PREFIX="$TMP_PREFIX" sh dist/linux-x86_64/install.sh
PATH="$TMP_PREFIX/bin:/usr/bin:/bin" WSM_ROOT="$TMP_PREFIX/sessions" wsm help
```

Then do one real installed-binary interactive sanity check, not just `help`:

1. `PATH="$TMP_PREFIX/bin:/usr/bin:/bin" WSM_ROOT="$TMP_PREFIX/sessions" wsm create test`
2. Type `echo hi`
3. Confirm the command executes and returns to the in-session prompt
4. Detach or terminate the session cleanly

Also do one detached sanity check through the installed wrapper so helper-binary CPU compatibility is exercised too:

1. `PATH="$TMP_PREFIX/bin:/usr/bin:/bin" WSM_ROOT="$TMP_PREFIX/sessions" wsm create -d smoke`
2. `PATH="$TMP_PREFIX/bin:/usr/bin:/bin" WSM_ROOT="$TMP_PREFIX/sessions" wsm list`
3. Confirm `smoke` appears and there is no `Illegal instruction`

Expected install layout:

- `bin/wsm`
- `libexec/wsm/host`
- `libexec/wsm/vpty`
- `libexec/wsm/ptylog`
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
