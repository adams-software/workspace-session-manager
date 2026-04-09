# Stream relay regressions

## 2026-04 composed `msr -> alt` clip stall

Observed behavior:
- `alt` standalone handled large OSC52/clipboard-style output correctly.
- `msr` standalone attach handled the same workload acceptably after server pacing improvements.
- Composing them as `msr -> alt` exposed a relay-specific stall where large output could appear hung or require extra input events to complete.

Representative repro:

```sh
./msr c -a /tmp/test -- ./alt --run bash -- bash
cat ../../msr/src/* | clip
```

## Root cause shape

This was not a plain `msr` bug and not a plain `alt` bug in isolation. The failure showed up only under composition, where partial writes and backpressure were more likely.

`alt` had queue-based buffering in both directions, but its poll loop only subscribed to `POLLIN` by default. When used as a middle relay layer, queued bytes could remain buffered after a partial write until some unrelated readable event arrived.

## Fix

In `alt/src/main.zig`:
- add `POLLOUT` interest on the tty side whenever `output_tx` is non-empty
- add `POLLOUT` interest on the child PTY side whenever `input_tx` is non-empty
- keep opportunistic same-iteration flushes so standalone responsiveness remains good

In `msr/src/server.zig`:
- `SessionServer.step()` now drains a bounded amount of ready work (`spins < 16`) per outer host tick to avoid sluggish one-pass progression on large bursts

## Testing guidance

When touching relay/pump logic, check all three cases:

1. `alt` standalone large clipboard-style output
2. `msr` standalone attach large clipboard-style output
3. composed `msr -> alt` large clipboard-style output

Composition can expose wakeup and backpressure bugs that do not appear in isolated tests.
