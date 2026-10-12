# Pause processors at the adapter source and report pause as operator intent

Status: Accepted

Date: 2026-10-12

## Context

Operators need reversible intake control without cancelling work or losing supervised lifecycle ownership. An adapter poll may already be admitted when a pause arrives, and adapters may prefetch beyond framework admission. Shutdown must still let a paused adapter deliver end of input.

## Decision

Each runner owns one TVar containing Nothing or the original pause timestamp. The ingester zips a waiting admission stream before the adapter source. No lock spans adapter IO. Already admitted polls, inbox messages and in-flight work may drain; adapter prefetch and leases remain outside this gate.

The master registry owns metrics and optional pause control together. Lifecycle validation, intent/timestamp update and cold metrics publication share one STM transaction. Successful outcomes return that transaction’s intake state. Repeated pause preserves its timestamp. Cold Failed alone is not terminal proof: retained lifecycles determine terminal control refusal. Failed/Stopped metrics outrank Paused. Sampling keeps live in-flight counts and the existing last-progress clock, so paused stuck handlers remain unready.

Shutdown atomically marks admission draining and clears all pauses before calling adapter shutdown. Subsequent operator control is refused, including races with shutdown. Forced master stop also takes admission ownership before cancellation. Legacy test/benchmark registrations without an actual runner retain their API and return not-controllable.

## Consequences

Pause is visible operator intent, not synchronous source quiescence. Existing in-flight work continues. Public application control lives in the core; HTTP lives in metrics. The new Paused constructor affects exhaustive matches; health adds paused and Prometheus adds state value 5. Tests use source and handler barriers to distinguish already admitted pulls from the next admission. One bounded remote quick comparison belongs to EP-52; this decision does not certify a release.

## Evidence

[EP-51](../plans/51-implement-source-level-processor-pause-and-resume.md), `shibuya-core/test/Shibuya/Runner/PauseSpec.hs`, and the metrics health, JSON, Prometheus and state round-trip tests cover admission, drain, lifecycle and observation behavior.
