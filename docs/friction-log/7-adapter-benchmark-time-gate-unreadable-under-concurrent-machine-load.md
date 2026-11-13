---
type: Friction Entry
title: "Adapter benchmark time gate unreadable under concurrent machine load"
description: "The PGMQ adapter benchmark comparison ran at load average 15-27 on 36 cores from other sessions, so single runs disagreed on which cells were slower and the DB-backed bench timed out on 8-10 cells on both sides."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T17:49:10Z"
frictionId: FRIC-7
status: "accepted"
impact: slowdown
kind: environment
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya-pgmq-adapter"
plan: "docs/plans/58-adopt-trace-correlation-in-the-pgmq-adapter.md"
workaround: "Read allocation first (identical within 4 B per pure cell, +/-2.4% on DB cells) and confirmed time with three interleaved base/candidate pairs at --stdev 3 on the flagged cells (median ratio 1.009, max 1.037), the method shibuya-core-bench/README.md prescribes"
resolution: "Interleaved, load-gated confirming pairs with allocation read first remain the accepted method on this shared machine; the DB bench cannot observe Shibuya changes and its timeouts occur on both sides"
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-13T17:49:11Z"
    change: "Accepted: the documented interleaved method resolved the gate for EP-5"
---
# Adapter benchmark time gate unreadable under concurrent machine load

## Attempted

Compare dlq-payload-bench and shibuya-pgmq-adapter-bench between v0.18.0.0 and 495c69a in clean worktrees with --fail-if-slower 10

## Encountered

dlq-payload-bench: 2/60 cells failed one run and 6 different cells exceeded 1.10 the next; DB bench: 12/70 failed (10 TIMEOUT after 120 s, baseline also 8 TIMEOUT) while the candidate's median time ratio was 0.81

## Workaround

Read allocation first (identical within 4 B per pure cell, +/-2.4% on DB cells) and confirmed time with three interleaved base/candidate pairs at --stdev 3 on the flagged cells (median ratio 1.009, max 1.037), the method shibuya-core-bench/README.md prescribes
