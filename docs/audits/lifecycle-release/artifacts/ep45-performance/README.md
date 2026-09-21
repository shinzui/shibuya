# EP-45 controlled core performance evidence

This directory contains the final matched production-runner comparison for the
EP-45 candidate.  It is performance evidence for
`docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md`;
it is not, by itself, the integrated release verdict owned by EP-44.

## Identity

- Released production baseline: `7512b5c692af1c005392e4445cfa26a9be41f9ea`
- Candidate production source: `6461c74cda5235e292d221f36621d09910b3b6f0`
- Shared workload harness: `6f5f5e237e6f5839b9e4ba2fe1e387e0c6b0bec2`
- Normalized solver-plan SHA-256:
  `abf44e86737d45737804d0391ccb67af16153b5b0340b9f4469500300015f9dd`
- Compiler and optimization: GHC 9.12.4, `-O2`
- Machine: MacBookPro18,2, Darwin arm64
- RTS cells: `-N1 -T -A32m` and `-N4 -T -A32m`
- Workload catalog: version 3, all 17 mandatory scenarios
- Comparator: deterministic paired bootstrap, 100,000 resamples, seed 45

The baseline worktree contains the shared version-3 harness without changing
the measured 0.9.0.3 production modules.  Baseline and candidate processes were
alternated within every segment, and each pair has one common `pairId` and
ordinal.  Every sample completed and acknowledged its expected work.

## Capture segments

The JSON datasets are the immutable final inputs to the checked-in verdicts.
Some near-boundary cells required more pairs.  Rather than weakening a budget,
the capture was extended under the same machine, compiler, solver, harness,
workload configuration, and alternating order.

For N1, the first segment captured all 17 scenarios with 40 pairs.  A second
segment captured 300 fresh pairs for `async-hot-key`, `serial-fixed-rate`, and
`startup-shutdown`; those higher-powered samples replace the corresponding
40-pair samples in the final datasets.  The final N1 files therefore contain
1,460 samples per variant.  Each segment had one unmeasured warmup per scenario.

For N4, the first segment captured all 17 scenarios with 40 pairs.  A second
segment captured 300 fresh pairs for `ahead-uniform-keys`, `async-hot-key`,
`health-poll-proxy`, `metrics-disabled`, and `websocket-churn-proxy`.  The
300-pair samples replace the initial samples for every listed scenario except
`async-hot-key`.  That cell remained narrowly inconclusive, so a third segment
captured another 1,000 pairs.  The final `async-hot-key` evidence combines all
three valid alternating segments (40 + 300 + 1,000 = 1,340 pairs) after assigning
unique ordinals and pair IDs; both extension offsets are even, so the documented
baseline-first/candidate-first parity is preserved.  The final N4 files contain
3,020 samples per variant.  `async-hot-key` had three unmeasured warmups; the
other extended scenarios had two.

The top-level `capture.warmupsPerScenario` value in each dataset describes one
warmup in an individual capture invocation.  The segment accounting above is
the authoritative explanation for scenarios assembled from more than one
invocation.

## Verdict

Both `final-verdict-n1.json` and `final-verdict-n4.json` report `pass` for all 84
measured scenario/metric cells.  No budget was changed after observation.  The
tightest N1 cell is `metrics-disabled` throughput, whose adverse 95% upper bound
is 1.04949 against the 1.05 limit.  The tightest N4 cells are
`async-high-cardinality` throughput (1.04763 / 1.05) and `async-hot-key`
maximum live bytes (1.04618 / 1.05).

`health-poll-proxy` and `websocket-churn-proxy` intentionally remain labelled as
core proxies in these files.  They do not claim wire-protocol coverage.  The
real HTTP and WebSocket measurements are separate EP-45 artifacts so their
protocol fidelity remains explicit.

## Live-adapter capture protocol

The live Kafka, PGMQ, and Kiroku artifacts use the exact core candidate above
and fixture commits in the owning repositories:

- `mori://shinzui/shibuya-kafka-adapter/packages/shibuya-kafka-adapter` at
  `0e2764571a7256279f47db286156e67c26142b79`; fixture path
  `shibuya-kafka-adapter-bench/app/LifecycleLive.hs`.
- `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` at
  `7a47ab7a6015e62b9ec932595129b9ccd4e1a3c6`; fixture path
  `shibuya-pgmq-adapter-bench/app/Endurance.hs`.
- `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` at
  `a1de2bf7dbb8b3209bda248a4cb29e071f85526e`; fixture path
  `shibuya-kiroku-adapter/app/LifecycleLive.hs`.

Every fixture emits the common CSV schema
`timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes`.
Each owns a unique topic, queue, or ephemeral database; performs a graceful
stop/restart at the midpoint; resumes the same durable group, queue, or
subscription; requires exact completed work, zero failures, zero final service
backlog, and a non-forced final stop; and samples current retained heap only
after a forced major collection. `scripts/audit/analyze-adapter-soak.ts`
applies the shared post-restart retained-memory and backlog gates.

The workloads and thresholds were fixed before the retained 120-second and
30-minute captures. Calibration runs are diagnostic and are not included in
the final artifacts.

| Adapter | Sustainable and soak target | Saturation target | Calibration observation |
| --- | ---: | ---: | --- |
| Kafka | 2 msg/s | 20 msg/s | 20 msg/s built a broker backlog; the corrected fixture drained 1,160/1,160 exactly. |
| PGMQ | 20 msg/s | 200 msg/s | 200 msg/s targeted and about 153 msg/s was achieved, with transient database queue backlog. |
| Kiroku | 20 msg/s | 200 msg/s | The synchronous append producer plateaued around 145 msg/s while the durable subscription kept pace. |

Sustainable and saturation captures run for 120 seconds, sample every 5
seconds, and restart at 60 seconds. The mandatory steady-state soak runs for
1,800 seconds, samples every 30 seconds, and restarts at 900 seconds. Soaks
use the sustainable rate. The service environment is Redpanda 26.2.1 (rpk
26.2.3) for Kafka and PostgreSQL 17.11 for PGMQ; Kiroku owns an isolated
PostgreSQL instance through `ephemeral-pg`. All live fixtures use GHC 9.12.4,
`-O2`, and `+RTS -N4 -T -A32m`.

All nine analyzed live-service runs pass. Each final count is exact, every
failure count and final durable backlog is zero, and every midpoint and final
stop is graceful.

| Adapter | Sustainable (120 s) | Saturation (120 s) | Soak (1,800 s) | Soak retained growth / slope |
| --- | ---: | ---: | ---: | ---: |
| Kafka | 240 / 240 | 2,321 / 2,321 | 3,593 / 3,593 | -4,032 B / -184 B/min |
| PGMQ | 2,274 / 2,274 | 18,483 / 18,483 | 34,653 / 34,653 | +424 B / +128 B/min |
| Kiroku | 2,251 / 2,251 | 17,917 / 17,917 | 34,605 / 34,605 | -1,632 B / -1,884 B/min |

The table cells show produced / processed totals. The soak slopes are far below
their precommitted allowances (about 18.7-19.3 KiB/min), and the first-to-last
post-restart median changes are far below the 262,144-byte absolute tolerance.

## Real HTTP and WebSocket workloads

Harness commit `b183861f3a29ef18fb104171e19d638ac31cdb20` adds a real Warp server,
persistent `http-client` requests, and actual WebSocket connections around the
EP-39 application. Under `-N4 -T -A32m`, `wire/health.json` records 100,000 / 100,000
successful `/health/ready` requests at 13,975 operations/second with p99 119 us.
`wire/websocket.json` records 10,000 / 10,000 successful connect, initial-snapshot,
and disconnect cycles at 5,107 operations/second with p99 295 us and a final
connection count of zero. These candidate stress runs supplement, rather than
replace, EP-39's 30-run baseline/candidate real-socket comparison in
`docs/audits/lifecycle-release/artifacts/ep39-metrics-lifecycle/websocket-snapshot-hyperfine.json`.

## High-cardinality batch memory envelope

`high-cardinality-envelope.json` contains five fresh processes at each of 1,000,
5,000, 10,000, 25,000, and 50,000 distinct in-progress batch keys under both N1
and N4. Every one of the 50 samples completed and acknowledged all input. The
conservative observed upper envelopes over that finite range are 692 bytes per
key under N1 and 703 bytes per key under N4; the largest observed high-water
heap was 23,976,216 bytes under N1 and 20,664,712 bytes under N4.

This measurement does not turn the envelope into a production bound. Distinct
in-progress keys remain unbounded by inbox capacity, so REV-15-L1 remains open
pending an explicit human release-owner acceptance (or a future implementation
limit). The performance verdict neither hides nor waives that residual risk.

## Aggregate verdict

`candidate-performance-verdict.json` indexes the two passing 84-cell core
verdicts, all nine passing live-adapter summaries, the real-wire artifacts, and
the measured high-cardinality envelope. No threshold changed and no waiver was
used. It is the EP-45 performance result consumed by EP-44; EP-44 still must
freeze versions and bounds, execute its exact-candidate matrix, obtain the
required independent review, and resolve REV-15-L1's human disposition.
