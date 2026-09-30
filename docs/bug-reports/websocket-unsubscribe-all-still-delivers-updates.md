---
type: Bug Report
title: WebSocket unsubscribe still delivers selected updates
description: >-
  Shibuya metrics 0.9.0.3 continues to stream a processor's updates after an
  Unsubscribe frame following subscribe-all.
generated:
  by: openai/codex
  at: "2026-09-27T23:56:57Z"
bugId: BUG-11
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-metrics
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 scenario suppresses the unsubscribed
  processor's updates while preserving updates from other subscriptions.
environment: >-
  Released Shibuya metrics 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with real loopback WebSocket frames and two named processors.
observed: >-
  On 0.9.0.3, Unsubscribe under subscribe-all leaves the subscription state
  interpreted as all processors, so the excluded processor still updates.
expected: >-
  A public Unsubscribe frame must stop updates for the named processor while
  other selected processors continue to stream.
reproduction:
  - Run the Kenshou websocket-unsubscribe-all-suppresses-updates scenario on the released 0.9.0.3 cohort.
  - Subscribe to all, exclude one processor, and observe REV-9-F3 when its updates continue.
  - Run the same scenario on Hackage 0.10.0.0; it passes.
workaround: >-
  On 0.9.0.3, subscribe to an explicit processor list that omits unwanted
  processors instead of relying on Unsubscribe after subscribe-all.
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
    context: "Status audit of cited sealed Kenshou results, cohort package identities, later local runs, and the 2026-09-29 baseline report. Retain fixed and fixedVersion 0.10.0.0: clean published-release controls pass while historical 0.9.0.3 runs reproduce the defect. Current controls at mori://shinzui/keiro-runtime-kenshou: runs/01a0e459-1f1a-71bb-a8bc-e2126fe483b3/run-result.json (project-relative paths; artifact-level URIs pending). Existing evidence was read; scenarios were not rerun."

---

# WebSocket unsubscribe still delivers selected updates

The clean released `shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates` scenario from `mori://shinzui/keiro-runtime-kenshou` reproduced `REV-9-F3` at `runs/01a0e479-ed61-76a8-8264-3b30756e2a90/run-result.json` (artifact-level URI pending). The pinned head passed at `runs/01a0e486-3ed0-7602-ad22-7eb39dd8cdbc/run-result.json`, and isolated Hackage 0.10.0.0 passed at `runs/01a0e459-1f1a-71bb-a8bc-e2126fe483b3/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` provides a live WebSocket metrics stream, and the public `Shibuya.Metrics.Types.Unsubscribe` frame names processors to remove. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` found that the historical push loop treats the subscribe-all state as all processors despite the attempted exclusion. This report concerns the subscription protocol, not slot accounting or endpoint enablement.
