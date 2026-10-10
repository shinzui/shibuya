# EP-48 WebSocket evidence

The baseline is `7a2527b` (in-band errors, before bounded delivery); the final production
candidate is `1e8b9f3d20e09d4258c9f5d26dab3c9d0a568ae9`. No core implementation or old wire
fixture changed. Package versions, harness hashes, compiler, optimization, and RTS flags are
recorded in each observer dataset. These are local development measurements, not a release
certification. EP-52 must repeat the integrated budgets with all six children present.

## Functional checks

The final candidate passes 90 metrics examples, 236 core examples, and both isolated core GC
suites; `cabal build all` and `nix fmt` pass. The metrics suite includes an exhaustive queue
transition model, exact error codecs, real sockets, controlled writer stalls, explicit producer
ticks, subscription boundaries, terminal retirement, error/snapshot adjacency, invalid-frame
saturation, and actual unread large-snapshot server shutdown. Existing JSON/Prometheus goldens
remain unchanged. Extension-tolerant clients can ignore the new error tag; closed legacy
sum decoders reject it, as the explicit compatibility characterization demonstrates.

`concurrency-repetitions.json` records ten repetitions each with `-N1` and `-N4`, seed
20260920, against the final candidate. All three controls in `mutation-controls.json` fail
behaviorally in a disposable checkout: unlimited required retention, a second application
writer, and resetting sampling on receive traffic. The corresponding `.txt` files contain
the failing examples. The script restores all mutations even on failure. Create the disposable checkout first:

```bash
git worktree add --detach /tmp/shibuya-ep48-mutants-final 1e8b9f3
python3 scripts/audit/run-websocket-mutation-controls.py \
  --checkout /tmp/shibuya-ep48-mutants-final \
  --output docs/audits/lifecycle-release/artifacts/ep48-websocket
```

The failing-first transcripts cover invalid-message timeout and missing subscription-limit
error at `30258cc`, the missing unsubscribe snapshot at `7a2527b`, and a terminal admission
that continued ordinary deltas after eviction at `e1fbebd`. The last regression's test seed
is 639195096. The fix stops deltas immediately and retires only admitted terminals.

## Sustained observers

The identical `ObserverLoad.hs` harness runs the production serial unordered runner with
inbox 16 and 2,000,000 acknowledged messages, while 1, 16, or 64 real WebSocket clients
receive updates every 10 ms. Client indices 1, 5, ... read every 100 ms, including the sole
client in the one-client case. Work starts only after every client receives its initial
snapshot. Core throughput, message creation-to-ack p95/p99, allocation per message, and RTS
live high-water memory are measured before percentile sorting. The latency sample list is
retained identically on both builds and contributes to the live-memory measurement. The
separate saturation fixture exercises genuine retained-frame pressure with controlled stalls.

The baseline checkout receives the same harness and Cabal stanza only; its production sources
remain at the baseline commit. The capture driver builds both binaries before sampling and
refuses differing harness hashes or selected package/version sets. `QuickCheck==2.15.0.1`
matches the candidate's existing solution; no repository dependency pin or bound was changed.
One warmup precedes each scenario; the scoped extension adds one 16-client warmup.
Odd pairs run baseline first; even pairs run candidate first. Every captured workload
completes exactly, observes application frames, releases all
server connection slots, and shuts down within 5100 ms. Do not run builds/tests concurrently
with these captures.

```bash
ep48_capture_dir=/tmp/shibuya-ep48-observer-reproduction # choose a fresh directory
git worktree add --detach /tmp/shibuya-ep48-red 7a2527b
git worktree add --detach /tmp/shibuya-ep48-candidate 1e8b9f3
git -C /tmp/shibuya-ep48-red apply "$PWD/docs/audits/lifecycle-release/artifacts/ep48-websocket/baseline-harness.patch"
python3 scripts/audit/capture-websocket-observers.py \
  --baseline /tmp/shibuya-ep48-red --candidate /tmp/shibuya-ep48-candidate \
  --constraint QuickCheck==2.15.0.1 --pairs 30 \
  --rts-flags '-N4 -qm -T -A32m' \
  --output "$ep48_capture_dir"
bun scripts/audit/compare-performance.ts \
  --baseline "$ep48_capture_dir/baseline.json" --candidate "$ep48_capture_dir/candidate.json" \
  --budgets docs/audits/lifecycle-release/artifacts/ep48-websocket/observer-budgets.json \
  --output "$ep48_capture_dir/verdict-thirty-pairs.json"
# Extend the sole inconclusive scenario; the first comparator exits 2.
python3 scripts/audit/capture-websocket-observers.py \
  --baseline /tmp/shibuya-ep48-red --candidate /tmp/shibuya-ep48-candidate \
  --constraint QuickCheck==2.15.0.1 --pairs 90 --clients 16 --resume \
  --rts-flags '-N4 -qm -T -A32m' \
  --output "$ep48_capture_dir"
bun scripts/audit/compare-performance.ts \
  --baseline "$ep48_capture_dir/baseline.json" \
  --candidate "$ep48_capture_dir/candidate.json" \
  --budgets docs/audits/lifecycle-release/artifacts/ep48-websocket/observer-budgets.json \
  --output "$ep48_capture_dir/verdict.json"
```

The unchanged budgets require at least ten pairs, 95% paired bootstrap confidence intervals
(10,000 resamples, seed 20260920), throughput/allocation/live-memory within 5%, p95/p99 within
10%, and bounded shutdown. Exit 2 is inconclusive, never a pass. The final controlled series
retains four capabilities and disables automatic thread migration with `-qm` on both sides.
Its final verdict is **pass** for all 18 scenario/metric cells, with 30/90/30 pairs at
1/16/64 clients
(150 pairs / 300 measured runs). The table gives the upper 95% confidence bound of each
adverse ratio, so smaller is better even for throughput. Limits are 1.05 for throughput,
allocation and live memory, and 1.10 for latency. Shutdown shows the maximum observed candidate
value against the 5100 ms absolute limit.

| Clients | Throughput ratio upper CI | Allocation ratio upper CI | Live memory ratio upper CI | p95 ratio upper CI | p99 ratio upper CI | Maximum shutdown ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 1.0038 | 1.0001 | 1.0000 | 1.0000 | 1.0482 | 0.264 |
| 16 | 1.0084 | 1.0011 | 1.0066 | 1.0045 | 1.0771 | 1.428 |
| 64 | 0.9814 | 1.0046 | 1.0249 | 1.0000 | 1.0145 | 5.402 |

All earlier diagnostic series are retained: `observers/` has ten-pair and thirty-pair verdicts
at `e1fbebd`; `observers-controlled/` has ten pairs at that same source with migration disabled;
`observers-final-native/` has ten default-RTS pairs at `ead6436`, after skipping empty queue
writes. These series have inconclusive confidence intervals and are not accepted as passing
gates. Default scheduling produced large latency/throughput shifts despite nearly identical
allocation in some pairs; worker placement is a plausible contributor, not a proven sole
cause. The controlled result does not certify every default-scheduler tail-latency outcome.
No pair or outlier was removed, and thresholds were not loosened.

## Saturation and churn

`saturation.json` records retained encoded bytes/frames, repeated live-heap samples after
required-frame saturation, and recovery of the blocked connection slot. Queue limits exclude
one writer-held frame and transient batch encoding; they do not promise a process-wide heap
bound or delivery of goodbye to a stalled peer.

`churn-before.json` and `churn-after.json` are the earlier 500-connection smoke reports.
`churn-matched-after-competing.json` preserves an intermediate run made while independent
checks were still active. `churn-matched-before.json` and `churn-matched-after.json` repeat
that smoke against the final
candidate with matching package versions and explicit RTS flags (`churn-context.json`).
Connection setup costs are
separate from the sustained-core budgets; a slower churn report is not hidden as a pass.

## Record validation

Capability and improvement-request profile/log enforcement passes. Strict mode also returns
nonzero for inherited missing recommended `reviews` metadata; those pre-existing advisories
are permitted by the plan, and are recorded separately from required-field failures.
