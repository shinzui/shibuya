---
type: Friction Entry
title: "Kafka adapter private Redpanda broker cannot be started"
description: "just redpanda-up (redpanda-local-up) and a direct container start of shibuya-kafka-adapter-rp-0 both hang with the container stopped, blocking the Kafka integration tests and the Jaeger check against a real broker."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T16:45:40Z"
frictionId: FRIC-6
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya-kafka-adapter"
plan: "docs/plans/57-adopt-trace-correlation-in-the-kafka-adapter.md"
workaround: "Ran the broker-free tests (scripted log, 63 passing) and deferred broker-backed integration tests and the Kafka Jaeger check; did not restart the container runtime because other projects' containers are running in it"
resolution: "redpanda-container 2107c28 / nix-haskell-flake 0.40.0 use the host container CLI and refuse version skew (Kafka commit 05accc5), and the wedged Apple Container network service was recovered by booting out and restarting every container job"
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-13T18:46:44Z"
    change: "Resolved: broker starts, Kafka integration tests and trace check passed"
---
# Kafka adapter private Redpanda broker cannot be started

## Attempted

Start the repository's private broker on 127.0.0.1:29092 to run IntegrationTest and the otel-producer-demo/otel-demo pair against the trace backend

## Encountered

redpanda-local-up printed 'Starting existing broker shibuya-kafka-adapter-rp-0...' and never returned (killed after 15 min); the devShell pins container client 1.1.0 against a 1.5.0 server, but a 1.5.0-client 'container start' also hung for 120 s; other stopped Redpanda containers in the same runtime are likewise stopped while long-running ones keep running

```text
container system status: client.version 1.5.0 server.version 1.5.0; nix devShell process: /nix/store/...-container-1.1.0/bin/container start shibuya-kafka-adapter-rp-0
```

## Workaround

Ran the broker-free tests (scripted log, 63 passing) and deferred broker-backed integration tests and the Kafka Jaeger check; did not restart the container runtime because other projects' containers are running in it
