# Let adapters supersede a delivery before its handler runs

Status: Accepted

Date: 2026-10-26

## Context

An adapter can arrange redelivery after records have entered the runner's inbox.
Acknowledgement fencing preserves offsets but cannot prevent those buffered
records from running handlers before the retry. Making an adapter emit one
record per finalization would remove ingestion headroom and starve batching.

## Decision

Add `DeliveryStatus` and an `Eff es DeliveryStatus` action on `Ingested`.
`mkIngested` defaults it to `DeliveryCurrent`. The runner reads it once at
processing admission, before handler, finalizer, in-flight ownership or outcome
accounting. A superseded single delivery records the existing acknowledgement
span event with value `superseded`, then ends successfully. It receives no
handler or finalizer call and advances no acknowledged cursor.

The shared batch worker samples each member once in order before its processing
span. The all-current path retains the original batch. Otherwise it preserves
current members in order and updates only `BatchInfo.size`; an empty result
performs no processing work or outcome accounting. Existing basic/detailed
specialization and masked slot ownership remain behind admission.

The action must return promptly, without side effects or synchronous exceptions.
Do not add an exception frame to this hot path. Unexpected failures propagate as
infrastructure failures; cancellation retains the existing ownership behavior.
A current answer is a snapshot, not a reservation against later revocation or a
concurrent retry. A batch has one admission snapshot, so processing a member
cannot retroactively exclude another member already given to the same handler.

Putting the check on `AckHandle` or `Adapter` would break every constructor. A
field on `Ingested` preserves smart-constructor consumers while requiring direct
record constructors to add `deliveryStatus = pure DeliveryCurrent` at migration.
There is no new counter or wire metric. Received counters remain ingestion facts.

## Consequences

Adapters own the decision about freshness, while the framework owns admission.
This is a source-breaking 0.12.0.0 candidate for direct record construction.
Performance acceptance remains governed by the existing benchmark and allocation
limits; this ADR does not waive a failed gate or certify a release.

## Evidence

Implementation and acceptance results are recorded in
`mori://shinzui/shibuya-kafka-adapter/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record`.
`SupervisedSpec`, `BatchProcessorSpec` and `SemanticSpec` cover admission, status
sampling, lifecycle failures, detailed ownership and tracing.
