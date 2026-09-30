---
type: Bug Report
title: Health probes ignore terminal processor and master state
description: >-
  Shibuya metrics 0.9.0.3 reports readiness after a configured processor fails
  and liveness after the application master stops.
generated:
  by: openai/codex
  at: "2026-09-27T23:49:23Z"
bugId: BUG-8
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-metrics
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 readiness and liveness scenarios pass after
  a configured worker fails and after the master stops, respectively.
environment: >-
  Released Shibuya core and metrics 0.9.0.3 and Hackage 0.10.0.0 on local
  macOS aarch64, with a loopback metrics server and one configured processor.
observed: >-
  The historical ready endpoint returns healthy after a required processor
  exits and unregisters, leaving an empty metrics map. The live endpoint
  returns healthy after the master stops because it can still read a TVar.
expected: >-
  A configured processor's terminal failure must remain visible to readiness;
  a stopped master must be reported unavailable by the liveness probe.
reproduction:
  - Run Kenshou ready-reflects-a-failed-processor on the released 0.9.0.3 cohort and observe REV-8-F1.
  - Run live-reflects-a-stopped-master on that cohort and observe REV-8-F2, including repeated stop.
  - Run both scenarios on Hackage 0.10.0.0; they pass.
workaround: >-
  On 0.9.0.3, use an independent supervisor lifecycle signal for health
  decisions rather than treating a successful metrics TVar read as proof of life.
reviews:
  - kind: model
    reviewer: openai/codex
    provider: openai
    model: gpt-6
    effort: unspecified
    reviewed_at: "2026-09-30T20:36:55Z"
    document_timestamp: "2026-09-27T23:49:23Z"
    scope: catalog-metadata
    outcome: approved
    context: "Status audit of cited sealed Kenshou results, cohort package identities, later local runs, and the 2026-09-29 baseline report. Retain fixed and fixedVersion 0.10.0.0: clean published-release controls pass while historical 0.9.0.3 runs reproduce the defect. Current controls at mori://shinzui/keiro-runtime-kenshou: runs/01a0e459-1935-7206-baa0-82f79790af66/run-result.json, runs/01a0e458-8a23-7078-b5b3-bc97aaa8e42c/run-result.json (project-relative paths; artifact-level URIs pending). Existing evidence was read; scenarios were not rerun."

---

# Health probes ignore terminal processor and master state

The clean released readiness and liveness scenarios from `mori://shinzui/keiro-runtime-kenshou` reproduced `REV-8-F1` at `runs/01a0e479-e310-7716-8cc3-af7b54e43fca/run-result.json` and `REV-8-F2` at `runs/01a0e479-4c79-736f-9bfa-9b85679160a2/run-result.json` (artifact-level URIs pending). The isolated Hackage 0.10.0.0 controls passed at `runs/01a0e459-1935-7206-baa0-82f79790af66/run-result.json` and `runs/01a0e458-8a23-7078-b5b3-bc97aaa8e42c/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` provides a health endpoint suitable for orchestrator probes. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-8` traced the historical readiness failure to unconditional processor unregistration and the liveness failure to reading shared state after master shutdown. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests retained configured identity and terminal failure information. These are two effects of health decisions made without lifecycle state; the report does not claim that every intentionally empty application must be unready.
