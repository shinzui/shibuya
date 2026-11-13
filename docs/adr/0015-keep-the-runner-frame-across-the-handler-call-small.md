# Keep the runner frame across the handler call small

Status: Accepted

Date: 2026-11-12

## Context

`Ahead n` and `Async n` processors run each message on a streamly worker thread, and streamly
forks and retires workers as the inbox fills and drains. GHC starts every new thread with a
1 KiB stack (RTS option `-ki`, default `1k`). A thread that needs more allocates a 32 KiB
stack chunk (`-kc`, default `32k`), and that chunk counts as allocation.

While a handler runs, the worker's stack holds the handler's own frames on top of a frame
where the runner saves every value it still needs after the handler returns. In 0.12.0.0 and
0.13.0.0 that frame held about 25 words: unpacked `Text` and `MetricsHandle` fields, the
effect environment, the `:>` dictionaries and more. On the `Async` benchmark cells the worker
stack sat within a word of 1 KiB. 0.13.0.0 added one word to the frame, which made more worker
forks overflow and cost 250–350 KB per run on `async-5`, with no change in time. 0.12.0.0
itself was already 6 words over the limit on one path.

## Decision

The runner keeps post-handler state out of the frame saved across the handler call.

- Code that runs after the handler returns lives in `OPAQUE` functions in
  `Shibuya.Internal.Runner.Supervised`: `finalizeMessage`, which finalizes and tail-calls
  `recordMessageOutcome`, which records the span outcome, the acknowledged cursor, metrics and
  any exit request.
- Per-processor values those functions need are bundled in one `FinishEnv` record, built once
  per processor and passed boxed. `OPAQUE` prevents GHC's worker/wrapper transformation from
  unpacking it into fields at the call site, which would put the fields back in the frame.
- The handler call itself (`runMessageHandler`) stays inlined into `processOne`. Making it
  `OPAQUE` too saves 6 more words but costs 10–40 bytes per message on every path, including
  `Serial`.

New work after the handler goes into `finalizeMessage` or `recordMessageOutcome` and reads its
inputs from their boxed arguments. Do not add values to `processOne` that live past the handler
call.

## Consequences

- On the `Async 5` benchmark the worker stack peaks 6 words under 1 KiB, so `Async` and
  `Ahead` cells allocate about half what 0.13.0.0 did. Serial paths keep 0.13.0.0's
  per-message cost.
- The margin is small and depends on GHC's code generation. A GHC upgrade or an innocent
  change to `processOne` can move it. The diagnostic for this, an `-ki` sweep and a stack
  decode, is in `shibuya-core-bench/README.md` under "Concurrent allocation moves while time
  does not".
- Real handlers that do I/O are likely to need more than 1 KiB anyway. For them this decision
  reduces the framework's share of each worker's stack, not the number of chunks. The
  benchmark cells measure the framework's share.
- Tracing behaviour, ordering, finalization, halt handling and the `n`-thread bound are
  unchanged. The split is internal to the runner and changes no public signature.

## Evidence

The measurements, the stack probe, the rejected hypotheses and the candidates compared are in
[`docs/plans/61-reduce-the-async-dispatch-allocation-increase-introduced-in-0-13-0-0.md`](../plans/61-reduce-the-async-dispatch-allocation-increase-introduced-in-0-13-0-0.md).
The change is commit `27bc701`.
