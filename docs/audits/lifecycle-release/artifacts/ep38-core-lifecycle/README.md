# EP-38 core lifecycle remediation evidence

This directory records the before/after correctness and focused performance evidence for
`docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md`.

## Identities and environment

- Audited behavior baseline: `ea0625e2e722af200c281843f209f94c6ca7036a`.
- Performance production baseline: `7512b5c692af1c005392e4445cfa26a9be41f9ea`.
  Its core source is identical to the audited baseline for the measured paths.
- Accepted implementation: `2108292e15c2cf79e40e8ca09a74604926beaedc`.
- Performance harness: `886f5910a5f1a47b5465dce9380bce831467fe2b`.
- Cabal solver-plan SHA-256:
  `47f9680ce1ad6be1220c85dfc30c850d097e20d4e97bef9d4394cbce30ec4dc4`.
- Compiler/profile: GHC 9.12.4, `-O1`.
- Host: Apple M1 Max, Darwin arm64.
- RTS comparison settings: `-N1 -T -A32m` and `-N4 -T -A32m`.
- Bootstrap confidence: 95%, seed `20260920`.

The performance datasets contain the complete identity and environment block. Baseline and
candidate processes alternate within each pair and share the same pair ID and workload
configuration.

## Correctness evidence

`lifecycle-probe-baseline.log` captures the old behavior. It demonstrates that:

- duplicate IDs silently lose the first processor handle and never signal its shutdown;
- one throwing adapter prevents the second shutdown and leaves `waitApp` blocked;
- batch, Async, Ahead and partitioned halt do not wake idle intake;
- exhausted finalizer retries appear as successful completion;
- keyed failure waits for the timeout while additional work continues; and
- `Async -1` and `Async 0` select unbounded behavior rather than failing validation.

`lifecycle-probe-candidate.log` captures the accepted implementation. Duplicate and
nonpositive policies are rejected before startup, every adapter is attempted, every halt
strategy wakes, exhausted finalization propagates `ProcessorFailure` with the message ID,
and keyed failure propagates immediately without processing later input.

The probe was compiled with:

```text
cabal exec -- ghc -threaded -O1 -XGHC2024 -package shibuya-core \
  scripts/audit/LifecycleProbe.hs -odir <external-temp> -hidir <external-temp> \
  -o <external-temp>/lifecycle-probe
```

`cabal-build-all.log` records `cabal build all --offline` succeeding. The fresh
`cabal-test-shibuya-core.log` records `cabal test shibuya-core --offline
--test-show-details=direct` succeeding against the accepted implementation: 236 ordinary
examples pass, `shibuya-core-gc-test` passes, and all six finished-application scenarios plus
their linked-supervisor negative control pass in `shibuya-core-gc-finished-test`.

`schedule-repetitions.log` records seeds 1 through 100 for each of these eight selectors,
all 100/100 passing:

- startup-owner cancellation at the ownership-transfer barrier;
- idle halt across every queue strategy and batch mode;
- concurrent and repeated graceful stop;
- cancellation during drain;
- exhausted finalization delivered exactly once under `StopAllOnFailure`;
- ticker failure while input is idle;
- keyed worker failure with infinite input; and
- restored interruptibility inside a supervised child.

## Performance acceptance

Budgets come unchanged from `docs/audits/lifecycle-release/performance-budgets.json`: at
most 5% throughput/allocation/live-memory regression, 10% tail/shutdown-latency regression,
and the precommitted absolute idle limits. No waiver or post-observation budget change was
used.

The original 30-pair complete runs are `paired-{baseline,candidate}-n{1,4}.json` with
`verdict-n{1,4}.json`. Their inconclusive cells triggered larger focused captures; an
inconclusive result was never treated as a pass. The accepted union is:

| Scope | Pairs per scenario | Verdict |
| --- | ---: | --- |
| N1 serial, async-hot-key, batch-size | 300 | all 18 cells pass in `active-verdict-n1-300.json` |
| N1 retry | 2,500 | all 6 cells pass in `retry-verdict-n1-2500.json` |
| N1 batch-timeout and idle-worker | 300 | all 12 cells pass in `residual-verdict-n1-300.json` |
| N4 serial, async-hot-key, batch-size, retry | 300 | all 24 cells pass in `active-verdict-n4-300.json` |
| N4 idle-worker | 300 | all 6 cells pass in `residual-verdict-n4-300.json` |

The N1 retry throughput result was the tightest active-path gate: adverse ratio `1.0341`,
95% CI `1.0203..1.0480`, limit `1.0500`. The N4 idle shutdown result was the last residual
gate: adverse ratio `0.9676`, 95% CI `0.8980..1.0435`, limit `1.1000`.

The `initial-regression-*` through `seventh-regression-*`, `masked-child-*`, and
`pre-io-boundary-*` files retain the candidate-development comparisons that found the keyed
restore-frame chain, masked supervisor/processor children, terminal-signal hot-path costs,
and whole-computation Effectful exception observer. They are diagnostic history, not the
accepted implementation verdict. The accepted datasets above all name the exact SHA
`2108292e15c2cf79e40e8ca09a74604926beaedc`.
