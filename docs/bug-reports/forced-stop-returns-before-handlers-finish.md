---
type: Bug Report
title: Forced application stop returns while handlers can still finalize
description: >-
  With four handlers blocked in the current batch, a forced application stop
  returns while those handlers are still active; opening their gate later lets
  them finalize after the caller was told the application had stopped.
generated:
  by: openai/codex
  at: "2026-09-27T19:02:09Z"
bugId: BUG-1
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-3
affectedVersion: "0.10.0.0"
environment: >-
  Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on a local macOS aarch64 host;
  synthetic public Adapter and four asynchronous handlers held at a gate,
  with a one-second drain timeout.
observed: >-
  stopAppGracefully returned False while four handlers remained active. A
  second stop call returned, but the handlers were still active. Opening the
  gate after both calls caused seven AckOk finalizations and seven handler
  completions before the replacement application started. Both tested
  releases reproduced the behavior.
expected: >-
  The published CAP-3 shutdown behavior and stopAppGracefully API state that
  remaining processors are force-stopped after the drain timeout. Once the
  call returns, a cancelled handler must not resume and finalize a delivery.
reproduction:
  - Publish 30 messages to a synthetic adapter with a five-slot inbox and four Async handlers blocked on one closed gate.
  - Wait for all four handlers to enter, then call stopAppGracefully with a one-second drain timeout; it returns False.
  - Call stopAppGracefully again and sample active handlers and finalizations while the gate stays closed.
  - Open the gate without starting a replacement and sample again; seven finalizations appear after the stop calls.
workaround: >-
  Keep the handler's side effects idempotent and fence old workers before
  starting a replacement. A process boundary with SIGKILL can enforce the
  stop boundary when an in-process forced stop is insufficient.
---

# Forced application stop returns while handlers can still finalize

The external scenario is `shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses` in `mori://shinzui/keiro-runtime-kenshou` (scenario artifact URI pending). Run it from that repository with `nix develop -c cabal run -v0 kenshou -- run shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses --out runs` on its released cohort, or with `nix develop -c cabal --project-file=cohort/shibuya-current.project run -v0 kenshou-shibuya-run -- run specs/shibuya-current-forced-shutdown.json runs` on its current cohort.

Clean-tree historical 0.9.0.3 produced `runs/01a0e449-8bb4-746f-86ca-3be1b8aadd6a/run-result.json`; current 0.10.0.0 produced `runs/01a0e44b-aea0-7459-966a-150ea1340c27/run-result.json` (both at `mori://shinzui/keiro-runtime-kenshou`, artifact-level URIs pending). Both used harness revision `5a308b6776136a702df834d944a3e770959c44c7` and recorded `activeHandlersAtStop=4`, `activeHandlersAfterSecondStop=4`, `finalizedAtStop=0`, and `finalizedAfterGateRelease=7`. The replacement eventually finalized all 30 messages, so this probe does not show message loss. It shows that the completion boundary is unsafe for clients that start a replacement or release resources after a forced stop. The revised scenario reports only the three scoped failure labels as nonblocking known defects; other failures still block.

The same gate and synthetic adapter pass through Shibuya's public `runApp`, `mkProcessor`, and `stopAppGracefully` APIs. The handler probe decrements its active count when a handler exits, including exceptional exit. The result cannot be explained by a delayed metrics sample: finalizer calls happen only after the gate is opened. The 0.10.0.0 stop implementation claims unconditional master cleanup after draining, but the test observes that asynchronous processor work remains able to run after the cleanup returns. This report leaves root cause to owner diagnosis.
