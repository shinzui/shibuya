---
type: Improvement Request
title: Implement designed processor pause/resume and expose gated control endpoints
description: >-
  Implement the already-designed source-level processor pause/resume and expose it through
  shibuya-metrics as explicitly gated control operations, disabled by default, so an operator
  can safely stop a processor from taking new work without expiring leases or killing the
  process.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-4
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Implement Designed Processor Pause/Resume and Expose Gated Control Endpoints

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/4-audit-shibuya-and-file-ui-endpoint-improvement-requests`).
This is the initiative's first control-plane request against shibuya — everything else filed
from keiro-ui is read-only. Implementation is shibuya's own downstream work.

## Context

Pause/resume is fully designed but entirely unimplemented (audited 2026-08-19 at commit
`7158f3e`: no `pause`/`resume` identifiers exist anywhere in `shibuya-core/src` or
`shibuya-metrics/src`). The design document `docs/plans/PROCESSOR_PAUSE_DESIGN.md` specifies
source-level pause — chosen over inbox-level pause precisely so that already-leased messages
drain normally and adapter leases/visibility timeouts do not expire mid-pause — including the
`ProcessorState` extension, the pause handle, the `MasterMessage` control-channel extension,
and a six-test plan. `docs/plans/METRICS_WEB_UI.md` already names control commands as the
metrics WebSocket's intended future.

For an operator UI, pause is the single most valuable safe intervention: it stops a
misbehaving processor from taking new work (a poison-message storm, a downstream outage)
without killing the process or losing in-flight work. But a control action on a surface that
today has no authentication (see
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-5`) must be explicitly gated:
the initiative's recorded posture is that mutating operations follow the owning project's
safety discipline and are separately enabled, never on by default.

## Requested Change

1. Implement the source-level pause/resume design from `docs/plans/PROCESSOR_PAUSE_DESIGN.md`:
   the paused state visible as a distinct `ProcessorState`, the pause handle plumbed through
   the `MasterMessage` control channel, and the design's test plan realized.
2. Expose pause and resume through `shibuya-metrics` as control operations that are **disabled
   by default**: with no explicit configuration, the control routes refuse (the server is
   read-only exactly as today). This request proposes configuration-level gating (an explicit
   opt-in flag or allowlist in the server configuration) as the minimum bar; shibuya chooses
   the concrete model and should record the decision durably (shibuya has no ADR corpus today;
   wherever shibuya keeps durable decisions is fine — the decision matters more than the
   venue).
3. Control responses and state changes are observable: a paused processor is distinguishable
   in `GET /metrics/<processorId>` and in WebSocket `update` frames, additively.

## Acceptance

1. Pausing a processor stops new message starts while already-in-flight messages drain and
   acknowledge normally; no adapter lease or visibility timeout expires as a result of the
   pause (the design's core property, demonstrated by test).
2. The paused condition is visible as a distinct processor state through the JSON endpoint and
   the WebSocket frames.
3. Resume returns the processor to normal intake, demonstrated end to end against a real
   adapter in a test.
4. With the control gate off (the default), the control endpoints refuse with a structured
   error and perform no action; with it on, they act. Both behaviors are covered by tests.
5. All wire changes are additive; pre-existing clients are unaffected.

## Requested Deliverables

The core implementation per the design document with its test plan, the gated
`shibuya-metrics` control surface with tests for both gate positions, documentation of the
gating configuration, and a durable record of the chosen gating model.
