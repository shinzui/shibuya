# Lifecycle release coverage contract

This document explains the machine-readable inventory in
`docs/audits/lifecycle-release/findings.json`. The inventory preserves every confirmed
finding, source concern, limitation, accepted assumption, and positive verification from
REV-1 through REV-16. It does not rewrite the historical reviews, and an entry in the
inventory does not mean that the underlying work is complete.

The stable key format is `REV-N-XM`, where `N` is the review ID, `X` is `F` for a defect,
`C` for an unconfirmed concern, `L` for a limitation, `A` for an accepted or pending
assumption, or `V` for positive verification, and `M` is the ordinal within that class.
Two reviews may describe the same underlying defect because each review remains independent
evidence. Their entries keep separate stable keys and converge on the same owner and
invariant.

## Confirmation and disposition

`confirmation` records how the claim was established: `runtime`, `source`, `verified`,
`documented`, or `unconfirmed`. Source evidence is a confirmed control-flow finding but is
not a live fault-injection result. `unconfirmed` identifies a concrete concern that the
release must reproduce or disprove.

`disposition.status` is one of `open`, `fixed`, `disproved`, `accepted`, `waived`, or
`out-of-scope`. `fixed` requires a fix SHA and a repository path to at least one regression
test. `accepted` is limited to assumptions, limitations, and positive verifications and
requires a rationale. A `waived` in-scope safety item requires a named human release owner,
rationale, expiry, affected release scope, and compensating controls. An agent cannot approve
its own waiver.

`out-of-scope` is not a synonym for fixed, disproved, or waived. It requires a named human
decision, decision date, reason, and affected canonical scope, and its component must be
absent from the candidate manifest. Every such entry is printed during release validation so
the final verdict can name the component as uncertified. The MessageDB entries carry the
project owner's 2026-09-19 decision that the deprecated
`mori://shinzui/shibuya-message-db-adapter` will not ship.

## Lifecycle boundary matrix

Every in-scope boundary has one owning child plan and five mandatory cases. `normal` proves
the ordinary successful path. `synchronousException` injects a failure from user, adapter, or
infrastructure code. `cancellation` interrupts the operation at an ownership boundary.
`timeout` proves the declared bounded-wait behavior. `repeatedStop` proves that a second stop,
shutdown, or terminal signal is safe and does not duplicate effects.

The inventory begins with each mandatory cell at `open`. A remediation child changes a cell
to `passed` only when it adds candidate-bound evidence references. A release manifest must
include one passing matrix run for every mandatory cell. A cell may instead be
`not-applicable` only when the inventory records a concrete reason. The only initial
not-applicable boundary is the excluded MessageDB adapter.

| Boundary | Owner | Normal | Sync exception | Cancellation | Timeout | Repeated stop |
|---|---|---:|---:|---:|---:|---:|
| Startup and registration | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Ingestion and backpressure | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Dispatch | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Keyed ordering | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Batching | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Retry and lease | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Finalization | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Drain and cancel | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Supervision | EP-38 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Metrics and health | EP-39 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Metrics WebSocket | EP-39 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Kafka persistence | EP-40 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| PGMQ persistence | EP-41 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| Kiroku persistence | EP-43 | Mandatory | Mandatory | Mandatory | Mandatory | Mandatory |
| MessageDB persistence | None; deprecated | Not applicable | Not applicable | Not applicable | Not applicable | Not applicable |

EP-38 completed all 45 mandatory cells for startup/registration through supervision at
implementation SHA `2108292e15c2cf79e40e8ca09a74604926beaedc`. The inventory points each
passed cell to the full core/GC run or the 100-seed schedule-repetition log, indexed by
`docs/audits/lifecycle-release/artifacts/ep38-core-lifecycle/README.md`. The remaining
in-scope adapter rows stay open for their owning children; this is not an integrated release
verdict.

EP-40 completed all five Kafka persistence cells at adapter implementation SHA
`554c969b1d95842628d0483f7ae6331c87249a84`. Evidence combines deterministic mock
interleavings with live Redpanda retry, restart, actual reassignment, and repeated-shutdown
cases, indexed by `docs/audits/lifecycle-release/artifacts/ep40-kafka-lifecycle/README.md`.
PGMQ and Kiroku remain open, and EP-45 still owns the final adapter performance matrix.

EP-39 completed all ten mandatory metrics/health and Metrics WebSocket cells at implementation
SHA `6535a036827c0bdfa1dd8c8a3ca9d228776f3f51`. The inventory points every passed cell to the
48-example real-endpoint metrics run, indexed by
`docs/audits/lifecycle-release/artifacts/ep39-metrics-lifecycle/README.md`. Normal, synchronous
exception, cancellation, timeout, and repeated-stop behavior are all explicit assertions rather
than source-only observations.

EP-44 owns integrated certification but does not overwrite child evidence. It assembles an
exact candidate manifest, confirms that every mandatory cell belongs to that candidate, and
reports all exclusions, waivers, residual limitations, and unexecuted cells. EP-45 supplies
the performance evidence referenced by the final verdict. Historical diagnostic scripts in
`scripts/audit/` remain observations until a child converts their scenario into an
assertion-based regression.
