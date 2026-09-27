---
type: Bug Report
title: Throwing adapter shutdown skips sibling cleanup
description: >-
  Shibuya core 0.9.0.3 lets one adapter shutdown exception skip later adapter
  shutdown actions and supervisor cleanup during graceful stop.
generated:
  by: openai/codex
  at: "2026-09-27T23:41:47Z"
bugId: BUG-6
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-3
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 scenario runs three processors, throws from
  the first adapter shutdown and confirms every sibling is signalled and
  processor intake stops.
environment: >-
  Released Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with three processors and one adapter shutdown that throws.
observed: >-
  On 0.9.0.3, the first shutdown exception exits the sequential shutdown loop;
  a sibling adapter is not called and supervisor cleanup is bypassed. The
  clean Kenshou run reports sibling-shutdown-skipped.
expected: >-
  CAP-3 assigns processor shutdown to the application handle. One failing
  adapter must not prevent the other started processors from receiving their
  shutdown signal and leaving the supervisor.
reproduction:
  - Run the Kenshou adapter-shutdown-failure-does-not-skip-siblings scenario on the released 0.9.0.3 cohort.
  - Have eight callers request graceful stop while the first of three adapter shutdown actions throws; observe at least one sibling not signalled.
  - Run the same scenario on Hackage 0.10.0.0; all contract checks pass.
workaround: >-
  On 0.9.0.3, make adapter shutdown actions catch and report their own errors
  while completing cleanup, then independently force-stop the application if
  graceful stop fails.
---

# Throwing adapter shutdown skips sibling cleanup

The released-cohort `shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings` scenario ran from `mori://shinzui/keiro-runtime-kenshou`. Its clean result `runs/01a0e46f-aa45-723f-a899-d6f2db105bce/run-result.json` (artifact-level URI pending) reproduced `sibling-shutdown-skipped`; the pinned head passed at `runs/01a0e47c-50e6-7403-acfd-04af75363b8f/run-result.json`, and the isolated Hackage 0.10.0.0 CLI passed at `runs/01a0e44f-6085-77a9-8db6-5d165e1201e8/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-3` assigns named-processor introspection and shutdown to the application handle. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-2` found the historical sequential adapter shutdown loop lacked a cleanup guarantee, and owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-3` reproduced the skipped sibling and incomplete `waitApp`. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests exception-safe cleanup and sibling signalling. This report concerns a throwing shutdown action; the separate total-deadline improvement for a forever-blocking action is outside its scope.
