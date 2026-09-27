---
type: Bug Report
title: Stale activity marks healthy processing stuck
description: >-
  Shibuya 0.9.0.3 retains an old processing-burst timestamp and can report
  actively progressing processors as stuck and unready.
generated:
  by: openai/codex
  at: "2026-09-27T23:49:23Z"
bugId: BUG-7
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 sustained-load scenario stays ready while
  processed counts advance and work remains in flight.
environment: >-
  Released Shibuya core and metrics 0.9.0.3 and Hackage 0.10.0.0 on local
  macOS aarch64, with an active Async 8 processor and a three-second stuck threshold.
observed: >-
  The historical processing state retains the first burst timestamp across
  later work. A clean released scenario reports a stuck-readiness failure
  despite increasing processed counts and in-flight work.
expected: >-
  A health check suitable for orchestrator readiness must not call a processor
  stuck solely because its first successful burst is old while later work
  continues to make progress.
reproduction:
  - Run the Kenshou ready-not-stuck-under-sustained-load scenario on the released 0.9.0.3 cohort.
  - Observe three progressing metrics samples while the readiness oracle reports REV-7-F1.
  - Run the same scenario on Hackage 0.10.0.0; it passes.
workaround: >-
  On 0.9.0.3, avoid using the built-in stuck-readiness result alone to restart
  a processor; correlate it with independent progress counters.
---

# Stale activity marks healthy processing stuck

The clean released `shibuya/metrics/correctness/ready-not-stuck-under-sustained-load` result from `mori://shinzui/keiro-runtime-kenshou`, `runs/01a0e479-51a0-7395-9fca-62dc811b2308/run-result.json` (artifact-level URI pending), reproduced `REV-7-F1`. The pinned head passed at `runs/01a0e485-a321-7215-9a94-e4524e3a142e/run-result.json`, and isolated Hackage 0.10.0.0 passed at `runs/01a0e458-8d0f-7366-a182-882199a4e398/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` describes a health endpoint suitable for orchestrator probes. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-7` found that the historical core metrics state does not clear the active flag after successful processing, so a later burst reuses an old timestamp. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requested a refreshed activity model and sustained-progress tests. The stale timestamp originates in `shibuya-core`; the false-unready symptom is exposed by `shibuya-metrics`.
