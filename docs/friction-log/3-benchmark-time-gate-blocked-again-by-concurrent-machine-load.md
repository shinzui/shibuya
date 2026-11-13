---
type: Friction Entry
title: "Benchmark time gate blocked again by concurrent machine load"
description: "The shibuya-core-bench time gate for plans 56 and 60 could not be read because another session's load benchmark kept the load average at 24-44 on 36 cores, so both time comparisons were deferred to a quiet window."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T02:40:10Z"
frictionId: FRIC-3
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya"
plan: "docs/plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md"
workaround: "Read allocation under load (serial cells are deterministic) and queued the time comparisons behind a wait for load below 8"
tags:
  - "benchmark"
  - "load"
---
# Benchmark time gate blocked again by concurrent machine load

## Attempted

Run the M2 gates: full shibuya-core-bench in worktrees at 40d112d and 2c2a580 and at HEAD e09be0c, then -p '/hot-path/ || /tracing/' three more times alternating 2c2a580 and HEAD

## Encountered

Load average 24-44 throughout (en-server-fresh at ~1400% CPU plus postgres). Pure streamly baselines moved 4-11% and lifecycle cells 22-100% between runs of the same code; single-async8 allocation varied by up to 12% across runs of an unchanged path. Serial allocation stayed within 1 KB per run.

```text
18:19-18:35 load average 23.6-44.5; ep3-base -> ep7-base single-async8 enabled cells -10% allocation with no change to that path
```

## Workaround

Read allocation under load (serial cells are deterministic) and queued the time comparisons behind a wait for load below 8
