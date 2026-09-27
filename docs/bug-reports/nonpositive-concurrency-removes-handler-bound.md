---
type: Bug Report
title: Nonpositive concurrency removes the handler bound
description: >-
  Shibuya core 0.9.0.3 accepts zero and negative Async or Ahead bounds and can
  run concurrent handlers beyond the configured limit.
generated:
  by: openai/codex
  at: "2026-09-27T23:25:08Z"
bugId: BUG-3
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-4
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The 0.10.0.0 policy rejects nonpositive Ahead and Async limits before intake;
  the sealed current-release Kenshou scenario passes.
environment: >-
  Released Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with finite blocking handlers under unordered Async and Ahead policies.
observed: >-
  On 0.9.0.3, Async 0, Async -1 and Ahead 0 are accepted and the Kenshou probe
  observes concurrent handlers. The owner audit measured 20 concurrent handlers
  for Async 0 and Async -1 with 20 finite messages.
expected: >-
  CAP-4 says Async n runs at most n handlers and contradictory policies fail at
  configuration time before intake. Nonpositive limits must be rejected before
  startup, with no source pull.
reproduction:
  - Run the Kenshou nonpositive-concurrency-is-rejected scenario on the released 0.9.0.3 cohort.
  - The scenario tests Async 0, Async -1 and Ahead 0 and records any accepted policy that runs concurrent handlers.
  - Run the same scenario on Hackage 0.10.0.0; all contract checks pass.
workaround: >-
  Configure a positive Ahead or Async bound on shibuya-core 0.9.0.3.
---

# Nonpositive concurrency removes the handler bound

The historical released-cohort scenario `shibuya/core-runner/correctness/nonpositive-concurrency-is-rejected` ran from `mori://shinzui/keiro-runtime-kenshou`. Its sealed `runs/01a0e479-0b13-7533-931e-5ca2efc25a1b/run-result.json` (artifact-level URI pending) reproduced `REV-6-F1`: `Async 0`, `Async -1` and `Ahead 0` were accepted and ran concurrent handlers. The pinned head passed at `runs/01a0e485-7fa4-73db-9fa0-d8b1f9d382e0/run-result.json`, and the isolated Hackage 0.10.0.0 CLI passed at `runs/01a0e458-7197-7433-87fa-13c492f1d17c/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-4` says `Async n` runs at most `n` handlers. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-6` separately observed a high-water mark of 20 for both `Async 0` and `Async -1` in a 20-message probe; it describes how the historical unordered runner passes these bounds to Streamly. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests early validation. This report records a fixed historical bound violation; it makes no claim of an out-of-memory incident.
