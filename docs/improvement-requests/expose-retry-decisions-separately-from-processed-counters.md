---
type: Improvement Request
title: Expose retry decisions separately from processed counters
description: AckRetry and AckOk both increment processed, so processor-labelled metrics cannot show how much work is being retried.
timestamp: 2026-09-25T22:42:29Z
requestId: IR-8
status: proposed
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
---

# Expose retry decisions separately from processed counters

## Current contract and observation

The [metrics architecture](../architecture/METRICS.md) and [message flow](../architecture/MESSAGE_FLOW.md) explicitly specify that both `AckOk` and `AckRetry` increment `stats.processed`; neither increments `stats.failed`. This is the implemented behavior, not a violation of the published counter contract. The independent synthetic brokers in `mori://shinzui/keiro-runtime-kenshou` observe one `AckRetry` and one `AckOk`, while the corresponding JSON and processor-labelled Prometheus samples both report received 1, processed 1 and failed 0. An operator cannot distinguish a successful completion from an attempt scheduled for retry using those metrics alone.

The live probe is scenario `shibuya/metrics/correctness/counters-distinguish-retries-from-success` in project-relative `kenshou-shibuya/src/Kenshou/Suite/Shibuya/Correctness/Metrics.hs`; its artifact-level URI and those of the run records are pending Mori coverage. Revision-2 sealed runs on historical Hackage 0.9.0.3 (project-relative `runs/01a0dac4-cd4a-7491-9a2d-caa464890139/run-result.json`) and pinned remediation head `6461c74cda5235e292d221f36621d09910b3b6f0` (project-relative `runs/01a0dac3-2f43-77c8-b3e7-d2795f467ac6/run-result.json`) both pass their documented contract oracle and retain the visibility gap under `implementationFindings`. The isolated Hackage 0.10.0.0 package test observes the same mapping; a sealed full-CLI run on that release is pending because `keiro-pgmq` excludes `shibuya-core` 0.10.0.0.

## Requested behavior

Expose an additive per-processor retry-decision count in JSON and Prometheus so a dashboard can tell a retry from an `AckOk` outcome. Keep the existing `processed` semantics until a separately versioned contract change is chosen. Define whether the new count tracks handler decisions, finalizer attempts, or successful finalizations; the current counters track decisions and must not imply durable acknowledgement. Include single-message and batch decisions, and test `AckOk`, `AckRetry`, dead-letter, handler exception and halt mappings independently.

This request is distinct from the stuck-readiness review `mori://shinzui/shibuya/okf/reviews/concepts/REV-7` and transient-exception state request `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-7`.
