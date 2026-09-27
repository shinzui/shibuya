---
type: Bug Report
title: Disabled WebSocket endpoint still accepts upgrades
description: >-
  Shibuya metrics 0.9.0.3 accepts WebSocket upgrades even when its
  enableWebSocket configuration flag is false.
generated:
  by: openai/codex
  at: "2026-09-27T23:56:57Z"
bugId: BUG-10
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-metrics
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The isolated Hackage 0.10.0.0 scenario rejects disabled WebSocket upgrades
  while an enabled endpoint still serves a snapshot.
environment: >-
  Released Shibuya metrics 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with loopback metrics servers under both WebSocket flag values.
observed: >-
  On 0.9.0.3, the combined application installs the WebSocket upgrade path
  without consulting enableWebSocket; a disabled endpoint still accepts a client.
expected: >-
  Setting enableWebSocket to false must disable the WebSocket upgrade endpoint
  while preserving other enabled metrics routes.
reproduction:
  - Run the Kenshou websocket-flag-gates-upgrades scenario on the released 0.9.0.3 cohort.
  - Observe a successful upgrade with enableWebSocket false and the REV-9-F2 label.
  - Run the same scenario on Hackage 0.10.0.0; it passes.
workaround: >-
  On 0.9.0.3, block the WebSocket route outside the metrics server if clients
  must not be allowed to upgrade.
---

# Disabled WebSocket endpoint still accepts upgrades

The clean released `shibuya/metrics/correctness/websocket-flag-gates-upgrades` scenario from `mori://shinzui/keiro-runtime-kenshou` reproduced `REV-9-F2` at `runs/01a0e479-e837-745e-94e6-6139cfc9d33e/run-result.json` (artifact-level URI pending). The pinned head passed at `runs/01a0e486-39a4-7686-aaa5-7e5b4df9d698/run-result.json`, and isolated Hackage 0.10.0.0 passed at `runs/01a0e459-1c2e-710e-b961-54f8b32d1701/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-10` includes endpoint enable flags. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-9` identified the historical unconditional WebSocket upgrade installation in the combined application; owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests the enablement regression. This report covers endpoint gating, not connection slot cleanup.
