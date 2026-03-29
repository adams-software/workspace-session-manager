# Virtual Session Navigation Library v1

Status: draft

## 1) Purpose

Define the first opinionated library layer above the explicit directory-scoped session manager.

This layer provides **filesystem-like virtual path semantics** over flat manager session names.

The goal is to let users and higher-level tools work with sessions as if they live in a hierarchical directory tree, while keeping the underlying manager/storage model simple.

This is still **library-first**. Any future CLI or TUI should be a thin expression of this library, not the place where the semantics are invented.

## 2) Relationship to lower layers

### 2.1 Core runtime
The core session runtime owns single-session lifecycle, attach semantics, control RPC, status, and wait semantics.

### 2.2 Explicit manager
The directory-scoped manager owns:
- explicit `(state_dir, name)` namespace lifting
- `resolve`
- `list`
- `exists`
- `status`
- `create`
- `terminate`
- `wait`
- `attach`

The manager remains **flat** and explicit.

### 2.3 Virtual navigation layer (this spec)
This layer adds:
- virtual hierarchical paths
- relative path resolution
- subtree/sibling navigation
- explicit-anchor-relative interpretation

It does **not** change the underlying manager storage model.

This layer should be understood as:
- the explicit manager API lifted from flat names to virtual paths
- plus a small set of navigation/path-specific functions

## 3) Design principles

- **Library first.** CLI/UX surfaces come later.
- **Filesystem semantics first.** User-facing path behavior should feel like ordinary filesystem path behavior.
- **No separate structure store.** Tree structure should be encoded in flat session names.
- **Keep manager flat.** Do not pollute the explicit manager layer with navigation policy.
- **Deterministic and scriptable.** Path resolution and navigation must be machine-friendly as well as human-friendly.

## 4) Core idea

The manager still stores sessions as flat names in one manager-owned directory.

The navigation layer treats those names as **encoded hierarchical keys**.

### 4.1 Encoded key model
A virtual session path is represented internally as:
- a sequence of path segments
- joined by a reserved delimiter value
- stored as one flat manager name

This gives:
- flat storage
- hierarchical interpretation
- lexicographic subtree queries via key-prefix scans

## 5) User-facing semantics

User-facing path syntax should feel like normal filesystem path syntax.

### 5.1 Supported path forms
- absolute paths: `/workspace/0`
- relative paths: `foo/bar`
- current-relative paths: `./foo`
- parent-relative paths: `../bar`
- repeated parent traversal: `../../baz`
- root path: `/`

### 5.2 Semantic goal
The behavior should match normal filesystem intuition as closely as practical:
- `/` means root of the virtual session namespace
- `.` means current anchor
- `..` means parent of current anchor
- path joining and normalization should feel like ordinary path resolution

The root namespace always exists conceptually, regardless of whether a root session exists.

## 6) Current context / anchor

This layer is the first place where a notion of “current session/path context” is allowed.

The navigation library should treat that context as an explicit **path anchor**.

Relative path resolution is performed against that anchor.

The anchor should be an explicit argument in library calls. v1 should not depend on hidden global mutable current-session state.

That keeps the semantics explicit while still enabling familiar relative path behavior.

## 7) Encoded name model

### 7.1 Delimiter
The internal flat name encoding uses a reserved delimiter value.

Chosen v1 delimiter:
- `:`

Reasons:
- filesystem-safe on Linux
- uncommon enough to reserve confidently
- easy to inspect/debug in flat names
- distinct from the user-facing `/` separator

### 7.2 User-facing path separator
User-facing virtual paths use normal `/` semantics regardless of the internal delimiter choice.

### 7.3 Segment constraints
User path segments must not contain:
- `/`
- `:`
- NUL

Empty path segments are not valid user segments after normalization.

The navigation library owns these constraints.

## 8) Why encoded hierarchical keys are desirable

This model avoids introducing a separate tree database or mapping table.

Benefits:
- no additional persistence layer required
- tree structure derived directly from encoded flat names
- subtree enumeration via prefix/range scan over manager names
- sibling discovery via parent-prefix scan
- parent/child relationships come from path decomposition itself

## 9) Library responsibilities

This layer should provide functionality in roughly four categories.

## 9.1 Path parsing / normalization
- parse user-facing virtual paths
- normalize `.` and `..`
- distinguish absolute vs relative paths
- resolve relative paths against an explicit anchor

## 9.2 Encoding / decoding
- encode path segments into flat manager names
- decode flat manager names back into path segments
- validate segments against delimiter constraints

## 9.3 Navigation helpers
- parent path
- child path
- sibling enumeration
- subtree enumeration
- maybe next/prev among siblings later

## 9.4 Lifted manager operations via virtual paths
This layer should expose the manager-style operations again, but with identifiers lifted to virtual paths plus an explicit anchor.

Conceptually:
- manager API: `(state_dir, name, ...)`
- navigation API: `(state_dir, anchor, virtual_path, ...)`

This keeps the layering pattern consistent:
- core lifts `path`
- manager lifts `(state_dir, name)`
- navigation lifts `(state_dir, anchor, virtual_path)`

The navigation/path semantics should still be defined first before binding every manager operation to them in implementation.

## 10) Suggested minimal API shape

This is intentionally library-oriented and explicit.

### 10.1 Pure path functions
- `parse(path_str)`
- `normalize(path)`
- `resolve(anchor_path, input_path)`
- `parent(path)`
- `join(base, rel)`

### 10.2 Encoding/decoding functions
- `encode(path_segments) -> flat_name`
- `decode(flat_name) -> path_segments`

### 10.3 Lifted manager operations
This layer should mirror the explicit manager API pattern by lifting identifiers from `(state_dir, name)` to `(state_dir, anchor, virtual_path)`.

Suggested lifted operations:
- `exists(state_dir, anchor, virtual_path)`
- `status(state_dir, anchor, virtual_path)`
- `create(state_dir, anchor, virtual_path, ...)`
- `attach(state_dir, anchor, virtual_path, ...)`
- `terminate(state_dir, anchor, virtual_path, ...)`
- `wait(state_dir, anchor, virtual_path)`

Absolute virtual paths ignore the anchor. Relative virtual paths resolve against it.

### 10.4 Discovery/navigation functions
Using manager `list(state_dir) -> []name` as input:
- `listChildren(state_dir, anchor)`
- `listSubtree(state_dir, anchor)`
- `listSiblings(state_dir, anchor)`

These functions can be implemented using lexicographic operations over encoded flat names.

Sibling ordering in v1 should be:
- numeric comparison when both compared sibling segment names are all digits
- otherwise plain lexicographic comparison

## 11) Discovery model over flat manager names

Because manager `list()` returns names only, this layer owns the higher-level interpretation.

### 11.1 Root session encoding
The root namespace is always conceptual.

A real root session may optionally exist.
If present, its encoded flat key is the delimiter by itself:
- `:`

Proposed model:
1. manager returns flat encoded names
2. navigation layer decodes them to virtual paths
3. navigation layer performs prefix/range filtering to derive:
   - subtree membership
   - child membership
   - sibling groups

This is the correct place for those semantics, not the manager layer.

## 12) Scope boundaries

## 12.1 In scope
- virtual path syntax
- relative/absolute path resolution
- encoded hierarchical key model
- subtree/sibling navigation semantics
- explicit anchor-based current-context behavior

## 12.2 Out of scope (for this v1)
- logging/replay/scrollback
- TUI
- rich interactive UX
- fuzzy search
- aliases
- persistence beyond what is inherent in encoded session names
- final composed product/binary behavior

## 13) Open questions

1. **Root session policy:** should higher layers encourage/use a real root session by convention, or leave it entirely optional?
2. **Top-level structure policy:** should any distinguished top-level categories ever be introduced by later layers, or should the root remain completely unconstrained?

## 14) Recommendation

Implement this as a separate library/module in the same repo, above the explicit manager library.

Sequence recommendation:
1. path parse/normalize
2. encode/decode
3. subtree/sibling queries over manager `list()`
4. only then bind manager operations through virtual path resolution

This keeps the semantics clean and prevents premature UX convenience from leaking into lower layers.
