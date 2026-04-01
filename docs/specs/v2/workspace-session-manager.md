# Workspace Session Manager (WSM) v0 Spec

## Status

Draft RFC for review.

## Purpose

Define a **hierarchical shell UX layer** that composes on top of:

* **`msr`** — minimal session runtime for a single session
* **`dsm`** — directory session manager for sessions within one directory

`wsm` is responsible for:

* discovering sessions recursively under one workspace root
* assigning each session a canonical workspace-relative identity
* providing a fast global jump command
* providing local node navigation once attached
* preserving deterministic, computable resolution semantics
* optionally enhancing UX with shell completion and interactive selectors

`wsm` does **not** redefine session semantics. It remains a composition layer over `msr` and, conceptually, over many DSM-style directories.

---

# 1. Non-goals

This spec does **not** define:

* changes to `msr` host/server/client protocol
* global daemon/registry/database
* collaborative sessions
* replay/logging
* stateful back/forward navigation history
* fuzzy matching that is opaque or heuristic-heavy
* mandatory interactive TUI dependencies

---

# 2. Design principles

1. **`msr` remains authoritative**
   Session lifecycle and attachment semantics stay in `msr`.

2. **Filesystem is the registry**
   Recursive directory structure under one root defines the workspace.

3. **Canonical identities are machine-first**
   Every session has a stable workspace-relative id.

4. **Jump is the primary global UX**
   Global navigation is search-based, not path-walking-first.

5. **Local cycling remains important**
   Once attached within a node, next/prev/first/last operate locally.

6. **Deterministic resolution over magical fuzzy logic**
   Search and ranking must be explainable and scriptable.

7. **Optional niceness must not change semantics**
   Completion and interactive pickers are UX enhancements only.

---

# 3. Core model

## 3.1 Workspace root

A workspace is a directory tree rooted at one explicit root path.

All session discovery happens recursively under this root.

## 3.2 Session files

A session is represented by a socket file with suffix:

```text
.msr
```

Examples:

* `shell.msr`
* `build.msr`
* `api/test.msr`

## 3.3 Directory node

Any directory under the workspace root is a **node** in the workspace tree.

Each node may contain zero or more `.msr` session files.

## 3.4 Canonical session id

Every session has a canonical id formed by:

```text
<workspace-relative-directory>/<session-name>
```

with the root directory omitted if empty.

Examples:

Workspace root:

```text
/work/proj
```

Session socket:

```text
/work/proj/pathdb/api/shell.msr
```

Canonical id:

```text
pathdb/api/shell
```

Root-level session:

```text
/work/proj/shell.msr
```

Canonical id:

```text
shell
```

This canonical id is the primary machine identity used by WSM.

---

# 4. Environment contract

When WSM creates a session, it must inject into the hosted process:

```text
MSR_SESSION=/absolute/path/to/socket.msr
WSM_ROOT=/absolute/path/to/workspace/root
```

These values are set at **session creation time**, not attach time.

## Rationale

This allows commands run inside the hosted shell/session to know:

* the current session socket
* the workspace root

without relying on shell cwd drift.

---

# 5. Workspace root resolution

WSM resolves workspace root in this order:

## Rule 1: explicit override

If command specifies root explicitly, use it.

Example:

```bash
wsm --root /work/proj j shell
```

## Rule 2: attached session context

If `WSM_ROOT` is set, use it.

This is the normal behavior while already inside a WSM-managed session.

## Rule 3: fallback

Use current working directory.

---

# 6. Current node resolution

When inside a session, WSM may derive the **current node** as:

```text
dirname(MSR_SESSION) relative to WSM_ROOT
```

Example:

* `WSM_ROOT=/work/proj`
* `MSR_SESSION=/work/proj/pathdb/api/shell.msr`

Current node:

```text
pathdb/api
```

This current node is used for local navigation commands:

* `next`
* `prev`
* `first`
* `last`
* `ls`

## Important rule

While attached, **current node is derived from `MSR_SESSION`**, not from live shell cwd.

---

# 7. Relationship to DSM

Each directory node under `WSM_ROOT` is effectively a DSM workspace.

That means:

* WSM performs recursive discovery across many nodes
* local node operations can conceptually reuse DSM logic
* WSM is hierarchical composition over many DSM-style directories

This is a core architectural assumption.

---

# 8. Primary UX model

WSM has two primary modes of use.

## 8.1 Global jump

Used to jump anywhere within the workspace from the root-scanned index.

Primary command:

```bash
wsm j [query]
```

## 8.2 Local node navigation

Used once attached within a node.

Commands:

```bash
wsm next
wsm prev
wsm first
wsm last
```

These operate only on sessions in the current node.

---

# 9. Command surface

## 9.1 Lifecycle / target commands

### `wsm new <target> [-- cmd ...]`

Create a session at target path.

Examples:

```bash
wsm new shell
wsm new pathdb/api/shell
wsm new pathdb/build -- cargo watch
```

Behavior:

* resolve workspace root
* resolve target canonical id
* create intermediate directories if needed
* derive socket path
* inject `MSR_SESSION` and `WSM_ROOT`
* delegate to `msr create`

---

### `wsm j [query]`

Global jump command.

Behavior:

* resolve workspace root
* recursively scan all sessions
* compute canonical ids
* resolve query deterministically
* attach to resolved target, or list candidates if incomplete/ambiguous

This is the primary WSM command.

---

### `wsm status [target-or-query]`

Resolve target and delegate to `msr status`.

---

### `wsm kill [target-or-query]`

Resolve target and delegate to `msr terminate`.

---

### `wsm wait [target-or-query]`

Resolve target and delegate to `msr wait`.

---

## 9.2 Inspection commands

### `wsm ls`

List sessions in the current node only.

If not inside a session:

* current node is the workspace root

### `wsm tree`

Recursively list all sessions under workspace root.

### `wsm current`

Print current session and workspace context.

Suggested output:

* canonical id
* socket path
* workspace root

---

## 9.3 Local navigation commands

### `wsm next`

Attach to next session in lexical order in current node.

### `wsm prev`

Attach to previous session in lexical order in current node.

### `wsm first`

Attach to first session in lexical order in current node.

### `wsm last`

Attach to last session in lexical order in current node.

These commands require `MSR_SESSION` and `WSM_ROOT`.

---

# 10. Target conventions

## 10.1 Canonical ids

Preferred machine form:

```text
dir/subdir/name
```

Examples:

* `pathdb/api/shell`
* `frontend/dev/test`
* `shell`

## 10.2 Socket path mapping

Canonical id maps to socket path:

```text
<WSM_ROOT>/<canonical-id>.msr
```

Examples:

* `pathdb/api/shell` -> `/work/proj/pathdb/api/shell.msr`
* `shell` -> `/work/proj/shell.msr`

---

# 11. Jump (`wsm j`) semantics

## 11.1 Purpose

`wsm j` is the primary global navigation command.

It is designed to be:

* fast
* deterministic
* scriptable
* completion-friendly
* optionally interactive

## 11.2 Inputs

`wsm j` accepts either:

### A. path-like canonical-id input

Examples:

```bash
wsm j pathdb/api/shell
wsm j pathdb/a
wsm j pathdb/api/
```

### B. token query input

Examples:

```bash
wsm j pathdb shell
wsm j api sh
wsm j dev test
```

The command may support both forms in one implementation.

---

## 11.3 Canonical discovery index

On each jump resolution, WSM computes an index of all sessions under `WSM_ROOT`.

For each session it computes:

```ts
type SessionRecord = {
  socketPath: string;
  canonicalId: string;   // e.g. "pathdb/api/shell"
  dir: string;           // e.g. "pathdb/api"
  name: string;          // e.g. "shell"
  tokens: string[];      // e.g. ["pathdb", "api", "shell"]
};
```

This index is the source of truth for all jump matching.

---

## 11.4 Query modes

### Path mode

If query contains `/`, it is treated as a canonical-id-oriented query.

Examples:

* `pathdb/api/shell`
* `pathdb/a`
* `pathdb/api/`

This mode works well with tab completion.

### Token mode

If query contains spaces, it is treated as a sequence of ordered search tokens.

Examples:

* `pathdb shell`
* `api sh`
* `dev test`

### Bare token mode

If query is a single token with no `/`, it is resolved by normal ranking rules.

Examples:

* `shell`
* `api`
* `path`

---

## 11.5 Matching and ranking rules

WSM must resolve candidates deterministically.

Recommended ranking order:

### Rank 1: exact canonical id match

Example:

* query: `pathdb/api/shell`
* candidate id: `pathdb/api/shell`

Highest priority.

---

### Rank 2: exact basename match

Example:

* query: `shell`
* candidate name: `shell`

Useful when only one such session exists.

If multiple exact basename matches exist, result remains ambiguous.

---

### Rank 3: exact token sequence match

Split canonical id into tokens by `/`.

Example candidate:

* `pathdb/api/shell` -> `["pathdb", "api", "shell"]`

Query:

* `api shell`

Matches exact ordered tokens.

---

### Rank 4: token prefix match

Each query token is a prefix of the corresponding candidate token in order.

Example:

* query: `pa ap sh`
* candidate: `pathdb/api/shell`

---

### Rank 5: ordered substring token match

Each query token matches candidate tokens in order by substring.

Example:

* query: `th db sh`
* candidate: `pathdb/api/shell`

This should be lowest priority if implemented.

---

## 11.6 Path-mode prefix behavior

If path-mode query is a prefix of one or more canonical ids:

### Unique leaf

Jump directly.

### Unique directory node with one leaf descendant

May jump directly, but v0 recommendation is to **treat as incomplete unless leaf is unique and obvious**.

### Multiple descendants

Treat as incomplete and list candidates.

Example:

```bash
wsm j pathdb/api/
```

If candidates are:

* `pathdb/api/shell`
* `pathdb/api/test`

then `wsm j` should list them instead of guessing.

---

## 11.7 Incomplete jump behavior

If query resolves to a directory node or ambiguous candidate set:

### If one unique leaf remains

Jump directly.

### If multiple candidate sessions remain

List matching canonical ids and exit non-zero or neutral, depending on your preferred scripting posture.

Recommended v0 behavior:

* print candidates
* exit non-zero for ambiguous resolution

### If no candidates remain

Print clear error and exit non-zero.

This keeps resolution explicit and computable.

---

## 11.8 No-query behavior

If user runs:

```bash
wsm j
```

recommended behavior:

* if interactive selector is available, open it with all sessions
* otherwise print all canonical ids or a tree/list and exit

This is a UX extension, not a semantic change.

---

# 12. Jump examples

Given sessions:

* `pathdb/shell`
* `pathdb/build`
* `pathdb/api/shell`
* `pathdb/api/test`
* `frontend/dev/shell`

### Exact id

```bash
wsm j pathdb/api/shell
```

Resolves directly.

### Bare token

```bash
wsm j build
```

Resolves to `pathdb/build` if unique.

### Token query

```bash
wsm j api sh
```

Resolves to `pathdb/api/shell`.

### Ambiguous token

```bash
wsm j shell
```

Candidates:

* `pathdb/shell`
* `pathdb/api/shell`
* `frontend/dev/shell`

List results, do not guess.

### Incomplete node

```bash
wsm j pathdb/api/
```

Candidates:

* `pathdb/api/shell`
* `pathdb/api/test`

List results, do not guess.

---

# 13. Local navigation semantics

These commands operate only on the current node derived from `MSR_SESSION`.

## 13.1 Session set

Enumerate direct `.msr` files in the current node directory only.

Do not recurse.

## 13.2 Ordering

Order is lexical filename order.

Example:

* `build.msr`
* `shell.msr`
* `test.msr`

Navigation:

* `first` -> `build`
* `last` -> `test`
* `next` from `shell` -> `test`
* `prev` from `shell` -> `build`

## 13.3 Wraparound

Recommended v0 behavior:

* `next` wraps end -> beginning
* `prev` wraps beginning -> end

This matches DSM semantics and feels natural.

---

# 14. Shell completion conventions

## 14.1 Scope

Tab completion is optional but recommended.

It must not change jump semantics.

Completion is only an assistive UI over canonical ids.

---

## 14.2 Virtual tree model

Completion should derive a virtual tree from the canonical ids.

From leaf ids:

* `pathdb/shell`
* `pathdb/api/shell`

derive virtual nodes:

* `pathdb/`
* `pathdb/api/`

and leaves:

* `pathdb/shell`
* `pathdb/api/shell`

This allows completion to behave like filesystem path completion over workspace session ids.

---

## 14.3 Completion behavior

Recommended behavior matches normal shell expectations:

### If exactly one match

Complete fully.

### If multiple matches share a longer common prefix

Complete to the longest common prefix.

### If still ambiguous

On repeated Tab, shell should show the list of matches.

Do **not** implement cycling as the default completion behavior.

This keeps behavior consistent with standard shell completion.

---

## 14.4 Examples

Input:

```bash
wsm j p<TAB>
```

Candidates:

* `pathdb/`
* `pathfinder/`

Completion:

* complete to longest common prefix if longer than input
* repeated Tab shows both candidates

Input:

```bash
wsm j pathdb/a<TAB>
```

Candidate:

* `pathdb/api/`

Complete to:

```bash
wsm j pathdb/api/
```

Input:

```bash
wsm j pathdb/api/s<TAB>
```

Candidate:

* `pathdb/api/shell`

Complete fully.

---

## 14.5 Completion modes

Completion is best suited to **path-mode** queries containing slash-separated canonical prefixes.

It does not need to fully support token-query fuzzy matching.

So the UX split is:

* slash-style input -> best completion experience
* space-token input -> best search experience

Both resolve to the same canonical identities.

---

# 15. Inspection commands

## 15.1 `wsm ls`

List direct sessions in current node.

If inside a session:

* node derived from `MSR_SESSION`

Else:

* workspace root node

Suggested output:

```text
build
shell
test
```

Optional current marker when inside session:

```text
build
* shell
test
```

---

## 15.2 `wsm tree`

List all canonical ids recursively.

Suggested simple output:

```text
pathdb/shell
pathdb/build
pathdb/api/shell
pathdb/api/test
frontend/dev/shell
```

Alternative prettier tree output is acceptable, but canonical-id listing is more scriptable.

Recommended option later:

* `wsm tree --ids` for plain canonical ids

---

## 15.3 `wsm current`

Suggested output fields:

* canonical id
* socket path
* workspace root
* current node

---

# 16. Error behavior

## 16.1 Jump no match

Print:

* no matching sessions found

Exit non-zero.

## 16.2 Jump ambiguous

Print:

* matching candidates

Exit non-zero.

## 16.3 Local navigation outside session

If `MSR_SESSION` or `WSM_ROOT` not set:

* print clear error
* exit non-zero

## 16.4 Missing session target

Delegate actual attach/status/kill/wait semantics to `msr`, but WSM should fail earlier when it can confidently detect no match.

---

# 17. Integration and implementation guide

## 17.1 Packaging model

WSM should be implemented as a shell-level package separate from `msr`.

Recommended project layout in a monorepo:

```text
packages/
  msr/
  dsm/
  wsm/
```

Recommended `wsm` layout:

```text
wsm/
  shell/
    wsm.sh
    completion.bash
  docs/
    WSM_SPEC.md
    INSTALL.md
  README.md
```

---

## 17.2 Installation model

Initial installation should be shell-sourcing based.

Example:

```bash
source ~/.local/share/wsm/wsm.sh
source ~/.local/share/wsm/completion.bash
```

Expected runtime dependency:

* `msr` installed on PATH

Optional dependencies:

* `find`
* `sort`
* `awk`
* `sed`
* `cut`
* `fzf` or `skim` for interactive selection

---

## 17.3 Suggested internal shell helpers

### Root/context

* `_wsm_root`
* `_wsm_current_socket`
* `_wsm_current_node`
* `_wsm_require_current_context`

### Discovery/index

* `_wsm_scan_sessions`
* `_wsm_canonical_id_for_socket`
* `_wsm_build_index`

### Matching

* `_wsm_match_query`
* `_wsm_rank_candidates`
* `_wsm_resolve_jump`

### Local navigation

* `_wsm_list_node_sessions`
* `_wsm_next_in_node`
* `_wsm_prev_in_node`
* `_wsm_first_in_node`
* `_wsm_last_in_node`

### Delegation

* `_wsm_attach_socket`
* `_wsm_create_target`
* `_wsm_status_target`
* `_wsm_kill_target`
* `_wsm_wait_target`

---

## 17.4 Suggested implementation strategy

### Phase 1

Implement canonical scan and plain `tree`.

### Phase 2

Implement deterministic `j` resolution in non-interactive mode.

### Phase 3

Implement local node navigation.

### Phase 4

Add Bash completion for path-mode canonical prefixes.

### Phase 5

Add optional interactive selector integration.

This keeps the implementation layered and testable.

---

# 18. Suggested Linux tools for implementation

You asked specifically about relying on existing tools.

## 18.1 Discovery

Recommended tools:

* `find`
* `sort`

Example conceptually:

```bash
find "$root" -type s -name '*.msr' | sort
```

If Unix socket matching is awkward across environments, you can relax to:

```bash
find "$root" -name '*.msr' | sort
```

and let `msr` remain authoritative on actual validity.

### Recommendation

For v0, scanning by filename suffix may be simpler and good enough.

---

## 18.2 Canonical id derivation

Recommended tools:

* shell parameter expansion
* `realpath`
* `sed`

Example idea:

* strip root prefix
* strip `.msr` suffix

---

## 18.3 Ranking/matching

Recommended tools:

* shell loops for clarity
* `awk` if you want concise token scoring
* avoid overcomplicated regex-heavy pipelines initially

My recommendation:

* implement the matcher in Bash functions first for readability
* only optimize later if needed

---

## 18.4 Interactive selection

Optional tools:

* `fzf`
* `sk`
* `peco`

Recommended model:

* WSM computes candidate set deterministically
* selector tool is only used to choose among already computed candidates

Do **not** make `fzf` the only matching engine.

---

## 18.5 Completion

Use standard Bash completion functions (`complete`, `compgen`) over the derived virtual-tree candidate set.

Recommended behavior:

* complete canonical prefixes and virtual nodes
* let Bash handle repeated-Tab listing behavior

---

# 19. Delegation contract to `msr`

WSM must continue to delegate actual session semantics to `msr`.

Required low-level commands:

* `msr create`
* `msr attach`
* `msr status`
* `msr terminate`
* `msr wait`

WSM must not:

* reimplement attach ownership logic
* reimplement runtime semantics
* maintain separate session truth

The filesystem and `msr` together remain authoritative.

---

# 20. Example usage

## Create

```bash
wsm new pathdb/api/shell
wsm new pathdb/build -- cargo watch
```

## Tree

```bash
wsm tree
```

Possible output:

```text
pathdb/shell
pathdb/build
pathdb/api/shell
pathdb/api/test
frontend/dev/shell
```

## Global jump

```bash
wsm j api shell
wsm j pathdb/api/
wsm j shell
```

## Local navigation

Inside `pathdb/api/shell`:

```bash
wsm next
wsm prev
wsm first
wsm last
```

---

# 21. Acceptance criteria

WSM v0 is successful if:

1. Sessions can be discovered recursively under one workspace root.
2. Every session has a stable canonical id.
3. `wsm j` resolves unique targets deterministically.
4. Ambiguous or incomplete jumps list candidates rather than guessing.
5. Local node navigation works from attached session context.
6. `MSR_SESSION` and `WSM_ROOT` are sufficient to derive current node.
7. Path-mode completion can construct canonical prefixes naturally.
8. WSM remains a composition layer over `msr`, not a second session system.

---

# 22. Recommended future extensions

Not part of v0, but natural later additions:

* `wsm j` interactive selector fallback
* upward workspace-root marker discovery
* richer `tree` display modes
* `--json` output for tree/current
* configurable matching strictness
* cached index for very large workspaces

---

# 23. Summary

WSM v0 should be understood as:

> a hierarchical workspace navigator that recursively indexes session sockets under one root, assigns canonical ids, uses deterministic global jump resolution, and preserves DSM-style local navigation within each directory node.

That is the cleanest framing, and it composes naturally with the architecture you now have:

* `msr` — one session
* `dsm` — one directory
* `wsm` — many directories under one root


## Current implementation notes

The first implemented WSM slice is intentionally narrow and mirrors lower layers where possible:

- commands currently implemented: `create`, `attach`, `current`, `status`, `exists`, `list`
- aliases currently implemented: `c/create`, `a/attach`, `s/status`, `e/exists`, `ls/list`
- `attach` is overloaded with global jump semantics rather than introducing a separate `j` command
- root resolution order is: `--root`, then `WSM_ROOT`, then shell cwd
- query resolution is deterministic:
  1. exact canonical id
  2. unique basename
  3. unique canonical suffix
  4. otherwise ambiguous/no-match
- current-session display uses the canonical workspace-relative id
- completion currently lives in `scripts/wsm_completion.bash`

This keeps WSM aligned with the same wrapper philosophy as DSM: preserve lower-layer semantics when possible and add only the minimum workspace-level resolution ergonomics.


## Search/completion direction note

The current implementation direction intentionally keeps runtime query resolution narrow:

- exact canonical id
- unique exact basename
- otherwise no match / ambiguous

The main interactive ergonomics are expected to come from canonical-id tab completion rather than richer runtime fuzzy matching. In practice, WSM ids behave like workspace-relative paths, so slash-aware hierarchical completion is the preferred UX for fast attach.
