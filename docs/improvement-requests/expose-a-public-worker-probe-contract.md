---
type: Improvement Request
title: Expose a public worker probe contract
description: >-
  Let deployed applications inspect Shibuya worker-loop liveness and readiness through a stable
  public API without importing framework internals or coupling workers to an HTTP server.
timestamp: 2026-07-30T14:36:35Z
requestId: IR-1
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: Expose a Public Worker Probe Contract

## Status

Proposed and blocking the worker-loop portion of Shikigami plan 29.

## Context

Shibuya 0.8 exposes public app construction, stop/wait, and metrics, but no public probe value that
an independently owned service/API package can translate into readiness and liveness. Importing
Shibuya internals into Shikigami workers, or importing Shikigami's HTTP server into the worker,
would violate both libraries' package boundaries.

## Requested Change

Expose a narrow public probe/snapshot contract for a running `App`. It should distinguish at least
not-started, healthy/running, stopping, stopped, and unexpected loop exit/failure, and include
enough stable identity to attribute the failed worker or subscription. Reading it must be
non-blocking and must not transfer acknowledgement ownership to the application. In
`shibuya-metrics`, provide an injectable generic WAI `probeApplication` (or equivalent) built from
`ProbeCheck` callbacks so worker-role executables can serve health without importing a sibling
application's API/server package. Keep consumer-specific health documents outside `shibuya-core`.

## Acceptance

1. Public-only tests observe startup, healthy running, requested stop, clean stop, and unexpected
   loop exit.
2. A probe read does not mutate worker state or acknowledge a message.
3. Multiple registered workers have attributable status and a documented aggregate readiness rule.
4. The `shibuya-metrics` probe application can be mounted/run independently and tested through
   injected checks; it does not depend on a consumer's domain/API package.
5. No consumer must import an `Internal` module.
6. The contract ships in a tagged release with lifecycle semantics documented.

## Requested Deliverables

- Public probe/snapshot types, read function, and injectable `shibuya-metrics` application.
- Concurrency/lifecycle/HTTP tests and documentation.
- Tagged release.
