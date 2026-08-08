---
okf_version: "0.2"
title: "Shibuya Capabilities"
type: capability-index
description: "What Shibuya provides today, one concept per capability, each with a stable CAP-N handle, an explicit compatibility promise, and evidence a reader can open."
generated:
  by: claude-opus-5/1
  at: "2026-08-08T00:00:00Z"
mori: shinzui/shibuya
links:
  - README.md
  - docs/user/getting-started.md
  - CHANGELOG.md
---

# Shibuya Capabilities

This directory is a typed [Open Knowledge Format](https://github.com/shinzui/okf) bundle
describing **what Shibuya does today**, for someone deciding whether to depend on it. Each
concept is one capability with a stable `CAP-N` handle, the released version it arrived in,
what compatibility promise it carries, and evidence a reader can open and check.

It is written for any consumer of Shibuya, not for one particular downstream system. Nothing
here assumes knowledge of the projects that happen to use it.

## What belongs here

A capability is a **provision claim**: something this repository's code does today, that a
consumer can adopt on its own, backed by evidence.

- **Not here: things that don't exist yet.** Those are improvement requests in
  [`../improvement-requests/`](../improvement-requests/). There is deliberately no `planned`
  status in the profile.
- **Not here: things that only work when several projects cooperate.** No single repository can
  assert or prove those; they belong to the consuming project as use-case features.
- **Granularity.** One capability is one thing a consumer can adopt *and* verify independently.
  Where two candidates always ship together and are proven by the same evidence, they are one
  capability.

## Reading the fields

- `status` — whether a consumer can use it right now (`shipped` / `deprecated` / `withdrawn`).
- `stability` — the compatibility promise. **Shibuya is pre-1.0, so every capability here is
  `experimental`**: the 0.8.0.0 cleanup stabilized the core API, but it may still change before
  the first stable release. See the [migration guide](../user/migrating-to-0.8.md).
- `since` — the released version in which the capability first became available. A capability
  that grew materially in a later release is recorded as its own concept (see `CAP-5`) rather
  than silently widening an older `since`.
- `packages` — what to add to `build-depends` to get it.
- `evidence` — artifacts proving the claim: tests, modules, examples, benchmarks, guides.
- `requires` — capabilities this one builds on. Each entry is declared **twice**: in frontmatter,
  where it is typed and may name an external `mori://` capability, and as a body link, where it
  becomes a graph edge. `okf` derives edges from body links only, so a frontmatter-only
  requirement validates cleanly and is invisible to `okf graph`.

## Index

| Handle | Capability | Since | Packages |
|---|---|---|---|
| [CAP-1](backend-agnostic-queue-processing.md) | Backend-agnostic queue processing | 0.1.0.0 | `shibuya-core` |
| [CAP-2](explicit-acknowledgement-semantics.md) | Explicit acknowledgement semantics | 0.1.0.0 | `shibuya-core` |
| [CAP-3](supervised-processing-with-backpressure.md) | Supervised processing with bounded backpressure | 0.1.0.0 | `shibuya-core` |
| [CAP-4](ordering-and-concurrency-policies.md) | Ordering and concurrency policies | 0.1.0.0 | `shibuya-core` |
| [CAP-5](partition-keyed-in-order-processing.md) | Partition-keyed in-order processing | 0.8.0.0 | `shibuya-core` |
| [CAP-6](first-class-batch-processing.md) | First-class batch processing | 0.8.0.0 | `shibuya-core` |
| [CAP-7](exponential-backoff-retries.md) | Exponential backoff retries with jitter | 0.4.0.0 | `shibuya-core` |
| [CAP-8](opentelemetry-tracing.md) | OpenTelemetry tracing | 0.1.0.0 | `shibuya-core` |
| [CAP-9](processor-introspection.md) | In-process processor introspection | 0.1.0.0 | `shibuya-core` |
| [CAP-10](metrics-endpoints.md) | Metrics endpoints over HTTP, Prometheus, and WebSocket | 0.1.0.0 | `shibuya-metrics` |

## Queue backends

Backends ship as their own repositories on their own release cadence, and describe their own
capabilities:

- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter)
- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)

## Validation

```sh
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce
```

[`profile.dhall`](profile.dhall) pins the shared `coordination.capabilities` profile from
[okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles) by Dhall semantic hash, so this
catalog and every other capability catalog are governed by one definition.
