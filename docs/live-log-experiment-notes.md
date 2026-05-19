# Live Log Experiment Notes

This note captures the first `scroll --stream` live-log attempt so we do not
repeat the same failure mode blindly.

## What was attempted

Goal: generate a live rendered `.log` alongside the existing `.typescript`
transcript.

Prototype approach:

- keep `script` as the transcript source
- wrap session startup in a supervising shell
- start `script ... session.typescript` in the background
- follow the transcript and feed it into `scroll --stream`
- write a live `session.log`

A branch containing that prototype was preserved as:

- `wip/live-log-stream-experiment`

## Why it was abandoned on `main`

The concept worked, but the integration point was too fragile.

Observed problems:

- startup regressions from the supervising shell / backgrounded `script`
- terminal-size behavior diverged from the older stable path
- multiple follow-on bugs appeared while trying to stabilize the wrapper model
- installed-binary mismatches made debugging more confusing in practice

## Current recommendation

Do not resume the wrapper-shell approach on `main`.

If live logs are revisited, prefer one of these:

1. a simpler FIFO-based `script -> scroll --stream` experiment on a branch
2. a lower-level tap inside `host` or `vpty`, where the byte stream already exists

The stable `main` line intentionally keeps the older transcript-based logging
model until a cleaner design is ready.
