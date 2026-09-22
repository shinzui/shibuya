# Exclude regressed effectful-core releases in every package

Status: Accepted

Date: 2026-09-22

## Context

Shibuya is built on `effectful`. The `effectful-core` changelog records that 2.7.0.0
"increased the per-operation overhead of dynamically dispatched effects", and that 2.7.1.1
fixed it. So 2.7.0.0 through 2.7.1.0 are the affected releases.

Shibuya core's own effects are statically dispatched, and its benchmark cannot tell 2.7.1.0
apart from 2.7.1.2. The adapters are different. The PGMQ adapter's `Pgmq` effect and the Kafka
adapter's `KafkaConsumer` effect are dynamically dispatched, so every queue operation takes the
regressed path.

Core 0.9.0.1 and Kafka adapter 0.9.0.1 widened their bounds to `<2.8`, which admitted the
regressed releases. At the same time, the PGMQ and Kiroku packages excluded effectful 2.7
entirely. So no single range worked across the cohort.

A bound on the umbrella `effectful` package cannot fix this. `effectful` 2.7.1.0 depends on
`effectful-core >=2.7.1.0 && <2.7.2.0`, a range that includes both the regressed 2.7.1.0 and
the fixed 2.7.1.1. Constraints in `cabal.project` do not help either, because they never reach
consumers.

## Decision

Every Shibuya package declares a direct `effectful-core` dependency with exactly this range,
in every component (library, tests, examples, benchmarks, fixtures):

```text
effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
```

Where a component also depends on the umbrella package, it declares
`effectful >=2.6.1 && <2.8` and keeps the direct `effectful-core` constraint beside it. A
package that imports only modules provided by `effectful-core` depends on `effectful-core`
alone.

This applies to shibuya-core, shibuya-example, shibuya-core-bench, and the supported adapters:
`mori://shinzui/shibuya-pgmq-adapter`, `mori://shinzui/shibuya-kafka-adapter`, and
`mori://shinzui/kiroku` (`kiroku-store` and `shibuya-kiroku-adapter`). A package in the solve
that imposes a narrower range blocks the cohort, so the range must be applied to it too, not
just to the adapter on top.

## Consequences

- Consumers can stay on effectful 2.6.1 or move to 2.7.1.1 or later. No combination of
  Shibuya packages can resolve to 2.7.0.0 through 2.7.1.0.
- The core carries the exclusion even though it is not affected itself. A consumer that
  depends only on the core is still kept off the regressed releases.
- Changing the range is a cohort change: update this ADR first, then every package listed
  above in the same release cohort, and run a combined solve for the accepted and rejected
  versions.
- Raising the upper bound past `<2.8` needs its own review of the new effectful-core changelog
  and the benchmark gate in
  [ADR 0006](0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md).

## Evidence

The core change, its dry-run solves, and the benchmark evidence are in
[`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`](../plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md).
The adapter changes and the combined solve are in
[`docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md`](../plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md).
That combined solve accepts 2.6.1.0 and 2.7.1.2, and rejects 2.7.1.0 at a declared package
bound. The range shipped on 2026-09-22 in shibuya-core and shibuya-metrics 0.10.0.0,
shibuya-kafka-adapter 0.9.1.0, shibuya-pgmq-adapter 0.16.1.0, kiroku-store 0.8.0.2, and
shibuya-kiroku-adapter 0.5.1.3. Coordination is in
[`docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md`](../masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md).
