# router v1 notes

This note captures the current intended shape of the next layer above `msr`.

## Purpose

The router is a very small terminal-owning process that:

- attaches to one `msr` raw child-data socket
- uses the matching `msr` control socket for resize coordination
- forwards the selected child stream directly to the user terminal
- exposes a separate router control socket for external orchestration

It is not intended to be the final UX.

A higher-level package can later sit above it and provide:

- hotkeys
- status bar
- TUI/picker UX
- session policy
- create/select logic

The router should stay focused and composable.

## Core model

The router owns the real terminal.

It has two planes:

1. **data plane**
   - router stdin/stdout
   - active raw child stream forwarded to the terminal

2. **control plane**
   - separate router control socket
   - small structured command protocol

The router is single-target in v1.

At any moment it is either:
- unattached
- attached to exactly one `{ data, control }` pair

## Attach model

Attach requires both:

- `data=<msr child socket path>`
- `control=<msr control socket path>`

The router will not support partial or view-only attach in v1.

### Important simplification

If the router is already attached, `attach ...` should return an error.

It should **not** implicitly switch or retarget.

Reason:
- keeps the component direct and predictable
- avoids branching/transition logic in the low-level router
- leaves switching/replacement policy to higher-level orchestration

Higher layers can always perform:
1. `detach`
2. `attach ...`

## Commands

Current intended command set:

- `attach data=... control=...`
- `detach`
- `state`
- `exit`

No `switch` command in v1.
No `create` command in v1.
No explicit signal/control proxying beyond resize behavior.

## `state`

`state` is preferred over `current` for consistency with `msr`.

Intended response shape is small and direct.

Examples:

- `ok attached=false`
- `ok attached=true data=/tmp/msr-a.sock control=/tmp/msr-a.ctl`

Additional fields may be added later if justified, but v1 should keep `state` minimal.

## Resize policy

Resize is automatic.

The router owns the real user terminal, so it is responsible for:

- observing actual terminal size
- reacting to terminal resize changes
- forwarding corresponding `resize` commands to the attached `msr` control path

There should be no separate router control command for normal resize operations in v1.

Resize is a consequence of terminal ownership on the data plane.

## Signal handling

No explicit signal-forwarding command is planned for router control v1.

The router should stay focused on:
- terminal forwarding
- attachment lifecycle
- resize synchronization

If more host/session signaling is needed later, it can be added when justified.

## Events

Events should stay sparse and lifecycle-oriented.

Potentially useful v1 events:

- `event attached data=... control=...`
- `event detached`
- `event stream_closed`
- `event exiting`

Guidance:
- do not emit noisy resize spam
- do not emit verbose socket chatter
- prefer only events that an external controller may genuinely care about

Event design can remain conservative until real callers prove they need more.

## Non-goals

The router v1 should not own:

- session creation
- session discovery policy
- hotkeys
- TUI UX
- multi-pane or multi-view rendering
- implicit retargeting/switch semantics
- broad proxying of all `msr` control calls

## Relationship to `msr`

`msr` remains responsible for providing the durable attach surface.

The router does not replace that responsibility.

Instead, the router composes with `msr` by:

- consuming the raw child-data socket for terminal visualization
- consuming the `msr` control socket for resize coordination

This preserves the current value of `msr` while adding a small terminal-owning layer above it.

## Why this shape

This design keeps the router useful as a low-level building block:

- it can visualize an `msr` session directly to a terminal
- it can be controlled externally from another process or terminal
- it stays small enough to embed under a richer future UX

The main principle is:

- keep the router simple
- keep policy above it
- keep the data plane primary and the control plane small
