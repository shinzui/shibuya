---
type: Bug Report
title: Exhausted finalizer is reported as a graceful halt
description: >-
  Shibuya core 0.9.0.3 converts permanent finalizer failure into a normal
  processor halt, hiding the failure from StopAllOnFailure supervision.
generated:
  by: openai/codex
  at: "2026-09-27T23:36:02Z"
bugId: BUG-5
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-2
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 Kenshou scenario passes the permanent
  finalizer-failure and supervision contract checks.
environment: >-
  Released Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with a finalizer that always throws under StopAllOnFailure supervision.
observed: >-
  On 0.9.0.3, bounded finalizer retries are exhausted, but the failure is
  converted to HaltFatal and caught as a normal processor completion; waitApp
  returns success despite the permanent finalization failure.
expected: >-
  The documented message-flow contract says permanent finalizer failure must
  surface as a loud processor failure. StopAllOnFailure must not interpret it
  as a requested graceful AckHalt.
reproduction:
  - Run the Kenshou finalization-failure-is-a-failure-not-a-halt scenario on the released 0.9.0.3 cohort.
  - Observe permanent finalizer failure and a successful waitApp result instead of a processor failure.
  - Run the same scenario on Hackage 0.10.0.0; it passes the contract oracle.
workaround: >-
  On 0.9.0.3, monitor adapter finalizer failures independently; a successful
  waitApp result does not prove that all finalizers succeeded.
---

# Exhausted finalizer is reported as a graceful halt

The historical released-cohort `shibuya/core-runner/concurrency/finalization-failure-is-a-failure-not-a-halt` scenario ran from `mori://shinzui/keiro-runtime-kenshou`. Its clean released result `runs/01a0e470-cabe-7653-8900-e5a10d838f31/run-result.json` (artifact-level URI pending) reproduced `REV-4-F2`; the pinned head passed at `runs/01a0e47d-4946-701e-b75a-0fbc8dea2e69/run-result.json`, and the isolated Hackage 0.10.0.0 CLI passed at `runs/01a0e450-5679-7122-bdaf-519bbd47bfd2/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-2` assigns finalization to the framework. Repository-local `docs/architecture/MESSAGE_FLOW.md` explicitly says a permanently failing finalizer is surfaced as a loud processor failure after bounded retries. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-4` observed the historical conversion to a requested halt and normal `waitApp` completion under `StopAllOnFailure`; owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests separating requested halt from infrastructure failure. This report concerns finalizer exhaustion, not a handler's deliberate `AckHalt`.
