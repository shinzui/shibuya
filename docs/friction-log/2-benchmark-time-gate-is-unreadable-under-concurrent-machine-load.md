---
type: Friction Entry
title: "Benchmark time gate is unreadable under concurrent machine load"
description: "The shibuya-core-bench time gate (+RTS -N, --fail-if-slower 10) reported 15-48% regressions in unchanged code while other workloads loaded the machine, costing three extra comparison runs."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T00:43:06Z"
frictionId: FRIC-2
status: "resolved"
impact: slowdown
kind: environment
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya"
plan: "docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md"
workaround: "Waited for load to fall to about 4-7 and reran; all but one microbenchmark then passed"
resolution: "shibuya-core-bench/README.md now tells gate runners to compare on an idle machine, check uptime, and trust allocation over time under load, explaining the -N parallel-GC sensitivity."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-13T00:43:07Z"
    change: "Documented the load sensitivity in the bench README"
---
# Benchmark time gate is unreadable under concurrent machine load

## Attempted

Run the EP-2 performance gate: baseline worktree at 526ddb1, then cabal bench with --baseline and --fail-if-slower 10

## Encountered

lifecycle/batch-size (code EP-2 does not touch) and other concurrent cells failed by 15-48% across three runs while allocation was flat or lower; load average rose from 4.7 to 23 from another project's test suites, a VM and mori

```text
lifecycle.batch-size cand-vs-base +48.4%, alloc +0.2%; load average: 23.82
```

## Workaround

Waited for load to fall to about 4-7 and reran; all but one microbenchmark then passed
