# Lifecycle and concurrency audit — completed

Completed 2026-09-20 UTC. **The audit is complete; remediation is not.**
This is the lifecycle/concurrency audit requested after the GC crash, not a
security audit, exhaustive concurrency proof, or live broker/database certification.
Registration-service-v2 was not examined.

## Release recommendation

The idle-master GC fix passes its dedicated regression and the ordinary core
suite. [REV-14](reviews/REV-14-master-fix-verification.md) approves that narrowly
scoped correction.

**Do not describe the current release as generally lifecycle-safe or ready on
the strength of those green tests.** The audit found reproducible halt, cleanup,
failure-reporting, and health problems. These are inherited issues, not changes
introduced by the master-loop removal. A release owner can assess a narrowly
scoped emergency GC hotfix separately, with those risks disclosed. The audit
does not grant blanket approval for the broader core/metrics or adapter releases.

Production changes were not made. Core remediation is tracked by
[IR-6](improvement-requests/close-lifecycle-and-health-audit-gaps.md), with explicit
regression acceptance. Existing IR-1 and IR-5 provide related public-probe and
metrics-test/interface work.

## Confirmed core and metrics findings

P1 means high priority; P2 means medium priority. Runtime evidence is local,
without external services. Source findings identify a concrete control-flow
failure but were not dynamically fault-injected.

| Priority | Finding | Evidence | Review |
| --- | --- | --- | --- |
| P1 | Concurrent and batch halt waits for new source activity instead of terminating | Runtime, with serial control | [REV-4](reviews/REV-4-supervised-halt-and-failure-audit.md) |
| P1 | Finalizer exhaustion becomes graceful completion under StopAllOnFailure | Runtime: four failures, successful waitApp | [REV-4](reviews/REV-4-supervised-halt-and-failure-audit.md) |
| P1 | Adapter shutdown exception skips sibling shutdown and supervisor cleanup | Runtime | [REV-3](reviews/REV-3-app-runtime-audit.md) |
| P1 | Cancellation during startup can bypass ownership cleanup | Source plus verified exception-library semantics | [REV-3](reviews/REV-3-app-runtime-audit.md) |
| P1 | Failed source disappears from readiness, which reports success | Runtime | [REV-8](reviews/REV-8-worker-health-audit.md) |
| P1 | Old activity timestamp makes healthy later processing appear stuck | Runtime | [REV-7](reviews/REV-7-metrics-activity-audit.md) |
| P2 | Duplicate IDs discard lifecycle handles after both processors start | Runtime | [REV-3](reviews/REV-3-app-runtime-audit.md) |
| P2 | Keyed worker failure is deferred indefinitely for an unending source | Direct scheduler runtime probe; production reachability bounded in review | [REV-5](reviews/REV-5-keyed-scheduler-audit.md) |
| P2 | Nonpositive concurrency values can remove intended resource bounds | Runtime: 20 simultaneous handlers at limits -1 and 0 | [REV-6](reviews/REV-6-concurrency-policy-audit.md) |
| P2 | Liveness still succeeds after stopping the master | Runtime | [REV-8](reviews/REV-8-worker-health-audit.md) |
| P2 | WebSocket disconnect/setup errors can permanently consume connection slots; disable flag does not gate upgrades | Source | [REV-9](reviews/REV-9-websocket-lifecycle-audit.md) |

REV-9 also records a lower-priority unsubscribe-all behavior mismatch. The batcher
review [REV-15](reviews/REV-15-batcher-lifecycle-audit.md) documents its cleanup,
bounded-output versus unbounded-key accumulation distinction, and the shared
halt dependency without inventing another reproduced defect.

## Adapter findings and release boundaries

| Adapter | Result | Evidence and scope |
| --- | --- | --- |
| Kafka | P1: a buffered later retry can move the barrier past an earlier unresolved offset; finalizer errors deferred to a terminated source can disappear | [REV-10](reviews/REV-10-kafka-acknowledgement-audit.md), complete adapter source review and concrete interleavings; no broker reproduction |
| PGMQ | P2 residual risk: lost commit confirmation can duplicate a DLQ copy despite transactional send/delete | [REV-11](reviews/REV-11-pgmq-lifecycle-audit.md), complete source review; ambiguous-commit fault not injected; documented prefetch redelivery is not classified as loss |
| MessageDB | P1: sparse category global positions pin checkpoints; pending retry can prevent shutdown and spin. P2: idle polling ignores shutdown, and checkpoint claims are removed before successful persistence | [REV-12](reviews/REV-12-message-db-lifecycle-audit.md), complete adapter source review plus executable ledger probes |
| Kiroku | P2: consumer-group acquisition/cancellation and cleanup failure can strand earlier subscriptions | [REV-13](reviews/REV-13-kiroku-lifecycle-audit.md), both adapter modules plus bridge source; no database fault injection |

The owning projects are respectively
`mori://shinzui/shibuya-kafka-adapter`,
`mori://shinzui/shibuya-pgmq-adapter`,
`mori://shinzui/shibuya-message-db-adapter`, and
`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter`.
No external repository was modified. These records are the handoff for
owning-project remediation; no external bug/IR creation or fix is claimed.
MessageDB's existing EP-36 compatibility work is separate from its runtime
protocol defects.

## Executed checks

- `cabal test shibuya-core --offline --test-show-details=failures`: ordinary suite
  **212 examples, zero failures**; isolated **GC test passes**.
- `cabal build lib:shibuya-metrics --offline`: passes.
- `cabal test shibuya-metrics --offline --test-show-details=failures`: reports
  **no tests to run**, not a passing metrics test suite.
- [LifecycleProbe](../scripts/audit/LifecycleProbe.hs): compiles and runs; repeated
  runs reproduce the same completion/failure classifications. Counts after a
  scheduler failure vary with scheduling.
- [HealthProbe](../scripts/audit/HealthProbe.hs): compiles and confirms false-ready,
  stopped-master liveness, and stale-burst false-unready behavior.
- [MessageDbLedgerProbe](../scripts/audit/MessageDbLedgerProbe.hs): compiles the
  actual external InflightState module without modifying it; confirms sparse
  checkpoint stalling and destructive checkpoint claiming. It does not execute
  the full adapter or simulate an actual database outage.

Representative observations:

```text
duplicate (wait, drained, first shutdown called): (Just (),True,False)
shutdown (threw, wait, second shutdown called): (True,Nothing,False)
batch halt (handler reached, wait): (Just (),Nothing)
single halt (Unordered,Serial) (finalized, wait): (Just (),Just ())
single halt (Unordered,Async 2) (finalized, wait): (Just (),Nothing)
single halt (Unordered,Ahead 2) (finalized, wait): (Just (),Nothing)
single halt (PartitionedInOrder,Async 2) (finalized, wait): (Just (),Nothing)
finalizer exhaustion StopAllOnFailure (wait result, attempts): (Right (Just ()),4)
scheduler (outcome, processed after failure): (Right Nothing,256)
Async -1 (wait, peak handlers): (Just (),20)
Async 0 (wait, peak handlers): (Just (),20)
Async 1 (wait, peak handlers): (Just (),1)
Async 2 (wait, peak handlers): (Just (),2)
after source failure: ready=True, total=0, failed=0, stuck=0
after master stop: alive=True
immediately after second burst starts: ready=False, total=1, stuck=1
fully acknowledged category beginning at global position 2: Nothing
checkpoint claims before/after an unpersisted claim: (Just 1,Nothing)
```

The harnesses print diagnostic observations; they do not exit nonzero merely
because a known defect is observed. They are **not CI release gates**. IR-6
requires converting them into assertions of corrected behavior.

## Reproduction

Run from this repository with its normal build environment. The commands below
match the local working manifests (0.9.0.2) and GHC 9.12.4; adjust inplace unit
IDs after a version bump. Outputs stay under the local `.tmp/lifecycle-audit`
directory, not alongside external source files.

```sh
cabal build lib:shibuya-core lib:shibuya-metrics --offline
mkdir -p .tmp/lifecycle-audit/health .tmp/lifecycle-audit/message-db
cabal exec --offline -- ghc -threaded -O1 -XGHC2024 \
  -package-id shibuya-core-0.9.0.2-inplace \
  -outputdir .tmp/lifecycle-audit -o .tmp/lifecycle-audit/probe \
  scripts/audit/LifecycleProbe.hs
.tmp/lifecycle-audit/probe

cabal exec --offline -- ghc -threaded -O1 -XGHC2024 \
  -package-id shibuya-core-0.9.0.2-inplace \
  -package-id shibuya-metrics-0.9.0.2-inplace \
  -outputdir .tmp/lifecycle-audit/health \
  -o .tmp/lifecycle-audit/health-probe scripts/audit/HealthProbe.hs
.tmp/lifecycle-audit/health-probe

audit_message_db_repo=$(mori path mori://shinzui/shibuya-message-db-adapter)
cabal exec --offline -- ghc -threaded -O1 -XGHC2024 \
  -XOverloadedRecordDot -XDuplicateRecordFields -package message-db-hs \
  -i"$audit_message_db_repo/shibuya-message-db-adapter/src" \
  -outputdir .tmp/lifecycle-audit/message-db \
  -o .tmp/lifecycle-audit/message-db-probe scripts/audit/MessageDbLedgerProbe.hs
.tmp/lifecycle-audit/message-db-probe
```

The MessageDB probe requires an installed compatible message-db-hs package; it
uses only that package's position type and the reviewed ledger source. This
avoids claiming compatibility of the older complete adapter with core 0.9.

## Examination boundary and provenance

Core and metrics source matched commit
`851c7c9db5d47593e2bd2899802c23bb06a231f7`; uncommitted release-manifest and plan
changes were preserved and excluded from the examination claims. Adapter source
commits are recorded in each review. REV-1 and REV-2 remain historical records,
not retroactively rewritten as runtime approvals.

Core lifetime paths examined: app validation/start/stop/wait, master ownership,
ingester completion, supervised ordinary/batch execution, halt/finalization,
keyed dispatch, batch accumulation, concurrency policy, hot metrics, health and
WebSocket lifecycle. Supporting inspection included tracing scopes, adapter
contracts, tests, and local NQE/UnliftIO/Streamly dependency implementation.
Adapters received full source review of their shipping Haskell modules.

No live PostgreSQL, PGMQ, Kafka, or Kiroku integration suite was run, and no
network/commit-loss fault campaign, exhaustive cancellation stress campaign,
security review, dependency-release-bound audit, or throughput benchmark is
claimed. Concrete source findings remain actionable without claiming such
tests. Candidate races not established as defects are explicitly described as
limits in the records, not counted as confirmed failures.

## Documentation validation

The review bundle passes strict profile/log validation: **15 concepts**.
The improvement-request bundle passes required profile/log validation:
**6 concepts**. Strict mode additionally flags missing recommended review
provenance on improvement-request documents; it is not reported as a strict
pass. There are no production fixes or release actions in this audit.
