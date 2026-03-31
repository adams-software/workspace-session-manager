# Lane Protocol (V2)

## Purpose

Define the canonical per-lane request/response protocol used by v2 transport/session layers.

This protocol is single-exchange, turn-based, pull-driven, and intentionally minimal.

## Model

A lane has two directions:

- request: initiator -> responder
- response: responder -> initiator

Rules:

- one active exchange per lane
- no per-message id
- exactly one response per request turn
- lane-local `seq` on every message
- streaming is pull-driven (`next`)
- cancel is a normal request turn

## Request messages

```ts
type LaneRequest =
  | { type: 'call'; seq: number; method: string; args?: any }
  | { type: 'next'; seq: number; args?: any }
  | { type: 'cancel'; seq: number; args?: any }
```

### `call`

Starts an exchange.

### `next`

Advances an active streamed exchange.

### `cancel`

Requests early termination of active exchange.

## Response messages

```ts
type LaneResponse =
  | { type: 'return'; seq: number; value?: any }
  | { type: 'opened'; seq: number; meta?: any }
  | { type: 'yield'; seq: number; chunk?: any }
  | { type: 'done'; seq: number; value?: any }
  | { type: 'error'; seq: number; error: any }
```

`yield.chunk` is opaque to lane protocol.

## Exchange lifecycle

### Unary

`call -> return` (terminal)

### Streaming

`call -> opened`, then repeated `next -> yield`, ending with `next -> done`.

### Cancel

`cancel -> done` or `cancel -> error` (terminal)

## Valid response constraints

- `call` -> `return | opened | error`
- `next` -> `yield | done | error`
- `cancel` -> `done | error`

Terminal responses:

- `return`
- `done`
- `error`

After terminal response, lane returns to idle and can start next exchange.

## Sequencing and ordering

- in-order per lane is required (`seq` monotonic by turn)
- out-of-order across lanes/sessions is allowed
- no unsolicited responder output (responses only to request turns)

## Interaction with v2 docs

- Session resume/replay policies: `transport-binding.md` and `operational-lifecycle.md`
- Flow-control windows/credits: out of lane scope (session/recovery layer)
- Subscription/signaling handoff semantics: `subscription-signaling.md` and `events-and-handoff.md`

## Error expectations

Examples:

- `call` while lane already active exchange -> `lane.error` (or equivalent)
- `next`/`cancel` with no active exchange -> `lane.error`
- invalid `seq` progression -> `lane.error`

Exact wire error envelopes are defined by transport binding/error namespace docs.

## Non-goals

- multiplexing multiple exchanges on one lane
- independent free-running bidi streaming on one lane
- message-level correlation ids
- replay/duplicate suppression policy
- flow-control credit policy

These belong to multi-lane/session/recovery layers.

