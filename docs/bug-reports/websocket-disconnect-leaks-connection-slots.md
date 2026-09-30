---
type: Bug Report
title: WebSocket disconnect leaks connection slots
description: >-
  Shibuya metrics 0.9.0.3 can retain a WebSocket connection slot after setup
  failure or peer disconnect, eventually denying new clients at the limit.
generated:
  by: openai/codex
  at: "2026-09-27T23:56:57Z"
bugId: BUG-9
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-metrics
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 WebSocket churn scenario passes slot,
  thread, descriptor and repeated-server-stop checks.
environment: >-
  Released Shibuya metrics 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with real loopback WebSocket connections and clean/abrupt peer closes.
observed: >-
  On 0.9.0.3, a close or setup failure can skip releaseConnection; the clean
  Kenshou churn scenario reproduces the REV-9-F1 slot-accounting failure.
expected: >-
  Every acquired connection slot must be released when the connection ends or
  setup fails, so a client disconnect cannot consume wsMaxConnections capacity.
reproduction:
  - Run the Kenshou websocket-slot-accounting scenario on the released 0.9.0.3 cohort.
  - Exercise snapshot setup, clean close, abrupt peer drop and repeated churn; observe REV-9-F1.
  - Run the same scenario on Hackage 0.10.0.0; it passes.
workaround: >-
  On 0.9.0.3, restart the metrics server if leaked slots exhaust the configured
  WebSocket connection limit.
reviews:
  - kind: model
    reviewer: openai/codex
    provider: openai
    model: gpt-6
    effort: unspecified
    reviewed_at: "2026-09-30T20:36:55Z"
    document_timestamp: "2026-09-27T23:56:57Z"
    scope: catalog-metadata
    outcome: approved
    context: "Status audit of cited sealed Kenshou results, cohort package identities, later local runs, and the 2026-09-29 baseline report. Retain fixed and fixedVersion 0.10.0.0: clean published-release controls pass while historical 0.9.0.3 runs reproduce the defect. Current controls at mori://shinzui/keiro-runtime-kenshou: runs/01a0e458-7469-7761-b745-4afcbd407e76/run-result.json (project-relative paths; artifact-level URIs pending). Existing evidence was read; scenarios were not rerun."

---

# WebSocket disconnect leaks connection slots

The clean released `shibuya/metrics/concurrency/websocket-slot-accounting` scenario from `mori://shinzui/keiro-runtime-kenshou` reproduced `REV-9-F1` at `runs/01a0e479-1266-76bf-af1a-2425ef444937/run-result.json` (artifact-level URI pending). The pinned head passed at `runs/01a0e485-84b2-74d8-abd3-0332f001b429/run-result.json`, and isolated Hackage 0.10.0.0 passed at `runs/01a0e458-7469-7761-b745-4afcbd407e76/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` says WebSocket connection state is bounded by `wsMaxConnections`. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` found that the historical cleanup bracket begins after some setup steps and that a throwing goodbye send can skip slot release. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests structurally scoped connection cleanup. This report concerns slot accounting and connection lifecycle, not subscription filtering or the endpoint enable flag.
