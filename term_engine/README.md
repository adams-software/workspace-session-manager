# term_engine

`term_engine` is the reusable terminal-state core for this repository.

It owns:

- the libvterm shim
- the Zig adapter around libvterm
- screen and cell snapshot types
- vendored terminal parsing dependencies

It does not own:

- PTY hosting
- runtime threads
- pager UI
- session orchestration

Current intended consumers:

- `vpty`
- `scroll`

## Intended public surface

At minimum, `term_engine` should provide:

- create terminal engine at a fixed size
- feed terminal bytes
- resize terminal state
- produce a screen snapshot

This package is intentionally small right now. The extraction goal is to keep terminal parsing/state reusable without dragging in live runtime concerns.
