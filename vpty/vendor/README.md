# vpty vendor

This directory contains third-party code vendored specifically for `vpty`.

## libvterm

Path: `vpty/vendor/libvterm`

Why it is vendored:
- `vpty` depends on libvterm internally
- we carry a small local OSC 8 hyperlink patch
- shipping the vendored copy removes the separate system `libvterm` install requirement

Local delta intent:
- add URI as a real terminal pen/cell attribute
- support OSC 8 hyperlink state in the terminal model
- expose hyperlink handles cleanly through `vterm_shim.c`

Practical rule:
- treat this as a minimal maintained delta, not a broad fork project
- prefer small, well-scoped changes
- document future local patches here when they are added

If rebasing/updating later, verify at minimum:
- `zig build`
- `zig build test`
- `zig build test-vterm`
- direct `vpty -- bash` smoke
- OSC 8 open/close behavior still works
