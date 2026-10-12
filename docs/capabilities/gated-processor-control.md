---
title: Gated processor intake control
type: Capability
description: Discover and apply explicitly enabled reversible processor pause/resume over HTTP with atomic lifecycle outcomes and actual-request origin checks.
generated:
  by: codex/gpt-6.1-sol
  at: "2026-10-12T19:50:09Z"
timestamp: 2026-10-12T19:50:09Z
capabilityId: CAP-11
provider: mori://shinzui/shibuya
status: shipped
stability: experimental
since: "0.10.0.1"
packages:
  - shibuya-metrics
interface:
  - Shibuya.Metrics.Control
  - Shibuya.Metrics.Config
requires:
  - CAP-10
  - CAP-9
evidence:
  - kind: module
    resource: shibuya-metrics/src/Shibuya/Metrics/Control.hs
    proves: Discovery, opt-in gating, exact-request origin checks and atomic outcome rendering.
  - kind: test
    resource: shibuya-metrics/test/Shibuya/Metrics/ControlSpec.hs
    proves: Both gate positions, methods, origin refusal, lifecycle outcomes and real HTTP/WebSocket pause/drain/resume behavior.
  - kind: guide
    resource: docs/adr/0011-gate-control-endpoints-off-by-default-and-refuse-with-a-structured-error.md
    proves: Default refusal, reversible operations and the host-owned authentication boundary.
---

# Gated processor intake control

`GET /control` discovers `enabled` and the pause/resume operations. `enableControl` defaults False. Disabled POST actions return 403 `control_disabled` and change nothing. Explicitly enabled pause/resume POSTs return the core transaction’s intake state and original pause timestamp; repeated operations are idempotent. Unknown, terminal, uncontrollable and draining processors have structured refusals.

Every supplied Origin must exactly match the configured allow list, even for simple/bodyless POSTs. Headerless CLI access remains supported. The server performs no authentication; a trusted network or authenticating reverse proxy owns that boundary. Paused observations use ordinary metrics and WebSocket update frames. Already admitted polls, inbox work and adapter prefetch may drain.

The `since` value names the current source package version. The release owner must update it to the version that publishes this unreleased capability; package publication is outside this initiative.
