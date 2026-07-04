# Migrating to shibuya-core 0.8.0.0

This guide covers upgrading an application (or an adapter) from `shibuya-core`
0.7.x to 0.8.0.0. Most changes are mechanical, but two of them —
`runApp`'s configuration argument and the handler's message type — touch
essentially every consumer, so almost nothing compiles unchanged.

If you only have a few minutes, do these two things and re-compile; the compiler
will point you at the rest:

1. Change `runApp <strategy> <inbox> …` to `runApp <AppConfig> …`.
2. Change any handler typed `Ingested es msg -> …` to `Message es msg -> …`
   (or use the `Handler es msg` alias), and stop reaching for `.ack` in handler
   code.

See the [0.8.0.0 changelog](../../CHANGELOG.md) for the full list of changes.

## 1. One import for application authors

There is a new umbrella module, `Shibuya`, that re-exports everything an
application author needs (running, config, processors, messages, handlers, ack
decisions, shutdown, telemetry). Prefer it over importing the individual
modules:

```haskell
import Shibuya
```

The individual modules (`Shibuya.App`, `Shibuya.Batch`, `Shibuya.Handler`,
`Shibuya.Core.*`, `Shibuya.Policy`, `Shibuya.Telemetry.*`) are still public, so
existing imports keep working — except for the runner internals, which moved
(see §4).

## 2. `runApp` takes an `AppConfig`

The positional supervision-strategy and inbox-size arguments are replaced by a
single validated `AppConfig` record. Invalid inbox sizes are now rejected before
startup (returned as an `AppError`, not a runtime failure).

```haskell
-- 0.7.x
result <- runApp IgnoreFailures 100
  [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler) ]

-- 0.8.0.0
result <- runApp defaultAppConfig
  [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler) ]

-- ...or spell out the config:
result <- runApp (AppConfig { strategy = IgnoreFailures, inboxSize = 100 })
  [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler) ]
```

`defaultAppConfig` is `AppConfig { strategy = IgnoreFailures, inboxSize = 100 }`.
`mkProcessor` and the `QueueProcessor` constructor are unchanged.

## 3. Handlers receive `Message`, not `Ingested`

The handler-facing type is now `Message es msg`, which carries the `envelope`
and an optional `lease` — but **not** the ack finalizer. Handlers return an
`AckDecision`; they no longer reach the low-level `ack` handle. This makes it
impossible to accidentally finalize a message from handler code.

```haskell
-- 0.7.x
type Handler es msg = Ingested es msg -> Eff es AckDecision

-- 0.8.0.0
type Handler es msg = Message es msg -> Eff es AckDecision
```

What this means in practice:

- Handlers that use `ingested.envelope` / `ingested.lease` and return an
  `AckDecision` compile unchanged **if** they rely on the `Handler` type alias.
  Both fields exist on `Message` with the same names.
- Handlers with an explicit `Ingested es msg -> …` signature must change it to
  `Message es msg -> …` (or use `Handler es msg`).
- Handlers that reached `ingested.ack` (to call `finalize` directly) no longer
  compile. Return the corresponding `AckDecision` instead
  (`AckOk` / `AckRetry` / `AckDeadLetter` / `AckHalt`).

Lease-based visibility extension is unchanged — `msg.lease` still yields the
optional `Lease`.

### The `Ordering` policy type is now `OrderingPolicy`

The ordering-policy type was renamed from `Ordering` to `OrderingPolicy`
(so consumers no longer need to hide `Prelude.Ordering`). The constructors
(`Unordered`, `StrictInOrder`, `PartitionedInOrder`) are unchanged — only the
type name changed, so update any explicit signatures or imports that referenced
`Ordering`.

## 4. Runner internals moved under `Shibuya.Internal.*`

The runner implementation modules are no longer part of the public API. If you
imported any of them directly (custom adapters, benchmarks, advanced
introspection), update the import path — and be aware that internal modules may
change without a major version bump from here on.

| 0.7.x module | 0.8.0.0 |
|--------------|---------|
| `Shibuya.Runner.Master` | `Shibuya.Internal.Runner.Master` |
| `Shibuya.Runner.Supervised` | `Shibuya.Internal.Runner.Supervised` |
| `Shibuya.Runner.Metrics` (metrics **types**) | `Shibuya.Core.Metrics` (public) |
| `Shibuya.Runner.{Halt,Ingester,Processor,Serial}` | internal to `Shibuya.Internal.Runner.*` |

Metrics types you introspect (`getAppMetrics` results) stay public via
`Shibuya.Core.Metrics` — you should not need `Shibuya.Internal.*` for normal
observability.

## 5. `AppHandle` and `Master` are now opaque

Their constructors are no longer exported. Use the accessor functions instead of
pattern-matching:

- `getAppMetrics` — snapshot the per-processor metrics.
- `getAppMaster` — get the supervision `Master` (also opaque; use its own API).
- `waitApp` — block until the app finishes.
- `stopApp` / `stopAppGracefully` — shut down (unchanged from 0.7.x).

## 6. `StopAllOnFailure` behavior change

`StopAllOnFailure` now maps to NQE's `IgnoreGraceful` supervision strategy: a
**graceful** child exit no longer stops its siblings — only a **failure** does.
This restores the documented halt-isolation behavior. If you relied on the old
(incorrect) behavior where any child exit tore down the app, revisit your
shutdown logic. `IgnoreFailures` correctly isolates a single failed processor.

## 7. Batching + ordering: unsupported combination now rejected

Batching processors reject `PartitionedInOrder` combined with `Ahead` or
`Async`, because batches are scheduled by `BatchKey`, not `Envelope.partition`.
This surfaces at policy validation (`runApp` returns a `Left AppError`) rather
than silently mis-ordering. Single-message processors *do* support
`PartitionedInOrder` with `Ahead`/`Async` (new in 0.8, via partition-keyed
dispatch).

## 8. Trimmed dependencies

`shibuya-core` no longer depends on `lens`, `generic-lens`, `effectful-core`,
`uuid`, or `vector`. This is transparent unless your package relied on picking
one of these up transitively through `shibuya-core` — in that case, add it to
your own `build-depends`.

## 9. For adapter authors

If you maintain an adapter (e.g. `shibuya-pgmq-adapter`, `shibuya-kafka-adapter`):

- Bump the `shibuya-core` bound to `^>=0.8.0.0`.
- The `source` stream still yields `Ingested es msg`; construct them with the
  `mkEnvelope` and `mkIngested` smart constructors (`mkEnvelope` fills the
  optional envelope fields with sensible defaults so you only set what you have).
  The framework projects `Ingested` to the handler-facing `Message` itself.
- If you construct `Envelope` by full record literal, note it already carries the
  `attempt`, `attributes`, `headers`, and `traceContext` fields added in 0.4–0.7;
  `mkEnvelope` is the forward-compatible way to avoid churn on future fields.

## What's new (not a migration step, but worth adopting)

- **First-class batch processing** — see `Shibuya.Batch` and `mkBatchProcessor`.
  Accumulate messages by key with size/timeout triggers and acknowledge a batch
  exactly once. Re-exported from `Shibuya.App` and the `Shibuya` umbrella.
- **Partition-keyed ordering** — `PartitionedInOrder` with `Ahead`/`Async` for
  single-message processors (per-partition FIFO, cross-partition concurrency).
- **Faster hot path** — per-message metrics are now atomic counters and the
  disabled-tracing path is allocation-free; no code change required to benefit.
