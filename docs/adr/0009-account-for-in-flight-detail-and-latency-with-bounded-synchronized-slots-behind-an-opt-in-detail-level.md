# Account for in-flight detail and latency with bounded synchronized slots behind an opt-in detail level

Status: Accepted

Date: 2026-10-10

## Context

Processor counters and sampler-side progress cannot answer processing duration or oldest
in-flight message identity. Per-attempt clock reads and synchronized ownership carry a cost,
so these features need an explicit host choice and candidate-bound measurements under
[ADR-0002](0002-require-candidate-bound-machine-checkable-release-evidence.md). The additive
wire and core/metrics package boundaries follow
[ADR-0007](0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md).

## Decision

Keep `MetricsBasic` as the default. Opt-in `MetricsDetailed DetailOptions` allocates one
slot per configured concurrent attempt, each with its own MVar and strict histogram shard.
Publish identity and monotonic start together under the slot lock. Zero is a valid start;
occupancy is a Maybe value. Never hold a slot lock across a handler or finalizer. Slot
exhaustion increments a diagnostic miss count; supported runner tests require zero misses.

Masked ownership transfer claims the slot, restores cancellation during processing, abandons
on exceptional exit, and releases once on completion. The basic branch has no detail bracket.
Select the mode once outside the loop through an OPAQUE accessor. Pass fully saturated
literal Bool arguments to INLINE loop/worker definitions so the compiler removes the detail
ownership closure from the basic specialization. Matching the handle inline expands three
basic worker closures by 40 bytes each; NOINLINE permits the worker/wrapper transformation
and does not suffice. Keep this constraint when adding cursor hooks. The
[GHC pragma reference](https://downloads.haskell.org/ghc/9.12.1/docs/users_guide/exts/pragmas.html)
documents the stronger OPAQUE guarantee.

Duration covers handler, finalization retries and metrics completion, once per message
attempt or emitted batch. A completed finalization failure counts; an interrupted attempt
does not. Batch identity is the first retained message. Existing runner entry points keep
their signatures and delegate to detail-aware variants. Validate positive concurrency and
nonnegative partition capacity before resource acquisition.

Each shard retains at most nineteen noncumulative bins, total count and nanosecond sum using
unbounded integers. Sampling copies each immutable shard under its lock and aggregates after
release. It is best effort across slots, while a slot's identity and timestamp always agree.
Monotonic starts convert relative to handle creation wall time. Slot scan and indexed release
cost grow with configured concurrency; detailed overhead is measured rather than assumed free.

Preserve the existing value-based JSON encoding order and omit unavailable detail members.
JSON latency has eighteen finite cumulative buckets; Prometheus adds `+Inf` equal to total
count and formats counts as exact integers. Emit oldest-age gauge only with an occupied
slot. WebSocket delta comparison zeros only age, and clients extrapolate elapsed age from
the last frame. HTTP and snapshots carry freshly sampled age. Cursor progress extends the
same detail configuration with a bounded partition table under
[EP-50](../plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md).

## Consequences

Direct `AppConfig` and `ProcessorMetrics` construction must supply new fields, while basic
wire objects retain their existing bytes. Detailed observation adds bounded state, allocation
and synchronization; it does not measure adapter queue wait or replace fleet aggregation.
Stable message identity may be visible to network clients when detail is enabled. No web
or low-level atomic dependency enters the core. A default change needs a separate explicit
decision backed by integrated evidence.

## Evidence

The implementation, deterministic tests, mutation checks and paired performance acceptance
are maintained in [EP-49](../plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md).
Performance acceptance remains pending until that plan records its measured verdicts; this
record fixes the architecture, without certifying a release or changing any budget.
