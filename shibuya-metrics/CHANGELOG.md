# Changelog

## 0.8.0.1 — 2026-07-04

Version bumped to track `shibuya-core` 0.8.0.1. No user-visible changes
to `shibuya-metrics` itself.

## 0.8.0.0 — 2026-07-04

### Breaking Changes

- Version bumped to track `shibuya-core` 0.8.0.0.
- The Prometheus endpoint no longer emits
  `shibuya_messages_dropped_total`; `shibuya-core` removed the always-zero
  `StreamStats.dropped` counter.
- Internal imports moved from `Shibuya.Runner.Master` and
  `Shibuya.Runner.Metrics` to the new public paths `Shibuya.App` and
  `Shibuya.Core.Metrics`. Application code using `shibuya-metrics` through
  `Shibuya.Metrics` does not need to change.

## 0.7.1.0 — 2026-06-15

Version bumped to track `shibuya-core` 0.7.1.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.7.0.0 — 2026-06-05

Version bumped to track `shibuya-core` 0.7.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.6.0.0 — 2026-05-31

Version bumped to track `shibuya-core` 0.6.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.5.0.0 — 2026-05-05

Version bumped to track `shibuya-core` 0.5.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.4.0.0 — 2026-04-29

Version bumped to track `shibuya-core` 0.4.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.3.0.0 — 2026-04-24

Version bumped to track `shibuya-core` 0.3.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.2.0.0 — 2026-04-22

Version bumped to track `shibuya-core` 0.2.0.0. No user-visible changes
to `shibuya-metrics` itself.

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- HTTP/JSON metrics endpoint
- Prometheus metrics endpoint
- WebSocket streaming metrics endpoint
- Kubernetes-compatible health check endpoints
