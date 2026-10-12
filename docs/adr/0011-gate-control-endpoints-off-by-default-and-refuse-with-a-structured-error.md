# Gate control endpoints off by default and refuse with a structured error

Status: Accepted

Date: 2026-10-12

## Context

A browser inspection client needs reversible intake control and a way to discover whether a host permits it. Browser CORS preflight cannot prevent all simple POSTs. The core already owns atomic lifecycle validation and returns the resulting intake state.

## Decision

One enableControl flag defaults False. GET /control discovers the flag and pause/resume operations in both positions. Disabled actions return 403 control_disabled without calling the core. Enabled POSTs validate the actual supplied Origin against an explicit allow list; duplicate/forbidden origins fail closed even for bodyless/text/plain requests. Headerless CLI access remains supported. Method checks precede gating; gating precedes Origin checks. enableJSON False hides the whole surface.

Use core ControlOutcome directly, calling it once and encoding its payload without a second metrics sample. Repeated pause/resume is idempotent, preserving the pause timestamp. Unknown processors are 404; retained terminal, uncontrollable and draining outcomes are 409. Every refusal uses the shared error/code renderer. Wrong methods return 405 with Allow. Paused state travels through existing metrics WebSocket update frames; no mutation frame is added.

Pause/resume destroy nothing and need no preview or confirmation ceremony. The server performs no authentication; trusted networks or authenticating reverse proxies own that boundary. Origin checking is not authentication. Any future destructive operation must revisit this policy in its own decision.

## Consequences

Control is opt-in and accessible through the bare WAI application as well as the built-in server. Same-origin browser control also requires its page Origin in the configured list. Source admission semantics and already-admitted-poll limits are inherited from [the pause decision](0010-pause-processors-at-the-adapter-source-and-report-pause-as-operator-intent.md). Direct MetricsServerConfig construction supplies the new flag. One bounded remote quick comparison is implementation diagnostic evidence, not release certification.

## Evidence

[EP-52](../plans/52-expose-gated-pause-and-resume-control-endpoints.md) and `shibuya-metrics/test/Shibuya/Metrics/ControlSpec.hs` exercise both gate positions, methods, origins, atomic outcomes, real HTTP/WebSocket behavior and graceful shutdown.
