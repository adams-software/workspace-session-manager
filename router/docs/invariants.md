# router/msr/wsm invariants

This document captures the current intended ownership and behavior boundaries.

## msr invariants

- one child process
- one raw data socket for PTY byte traffic
- one active owner at a time on the data socket
- latest owner wins
- no replay, output produced without an owner may be discarded
- no structured control messages on the data socket
- structured host control uses ctlwire over a separate control surface

## router invariants

- router is a component, not a daemonized service boundary
- router has at most one active target attachment at a time
- router owns one active data-plane attachment to the selected target
- router owns one parent control channel
- router never discovers sessions
- router never creates sessions
- router never owns UX policy
- router may relay structured control to the attached target only when an optional target control endpoint is provided
- in the minimal attach shape, router only forwards terminal bytes
- physical session state and logical runtime state must move together

## router attach semantics

- `attach data=<path>` is the minimal contract
- `attach data=<path> control=<path>` enables richer behavior
- `data` is the target PTY byte stream
- `control` is optional target ctlwire control
- if target control exists, router may send initial and subsequent resize commands
- if target control does not exist, attach still works as plain byte forwarding

## wsm invariants

- wsm owns UX policy
- wsm owns session discovery and selection
- wsm owns router lifecycle
- wsm owns higher-level session references and metadata
- wsm decides when router exists, what it targets, and when it is replaced or torn down
- router is not globally addressable in the intended final embedding

## embedding direction

The intended long-term shape is:

- `wsm` spawns `router` as a child component
- `router` data plane remains stdin/stdout oriented for terminal traffic
- `router` control plane is a private inherited fd using ctlwire
- named router control sockets are a debug/bring-up path, not the ideal product boundary
