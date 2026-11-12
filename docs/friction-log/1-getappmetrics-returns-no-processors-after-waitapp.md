---
type: Friction Entry
title: "getAppMetrics returns no processors after waitApp"
description: "Shibuya.App.getAppMetrics reads the master's live registry, which drops finished processors, so a caller cannot read final counts through the public API after waitApp."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-12T23:15:38Z"
frictionId: FRIC-1
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya"
affectedVersion: "0.12.0.0"
plan: "docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md"
workaround: "Read each SupervisedProcessor's own metrics via Shibuya.Internal.App.AppHandle(processors) and Shibuya.Internal.Runner.Supervised.getMetrics"
---
# getAppMetrics returns no processors after waitApp

## Attempted

Count processed messages in the tracing benchmark with getAppMetrics after waitApp on a finite list adapter

## Encountered

Every cell failed with 'processed 0 of 10000'; getAllMetricsIO traverses registry.liveMetrics, from which a finished processor has already been removed

```text
Exception: user error (Bench.Tracing: processed 0 of 10000)
```

## Workaround

Read each SupervisedProcessor's own metrics via Shibuya.Internal.App.AppHandle(processors) and Shibuya.Internal.Runner.Supervised.getMetrics
