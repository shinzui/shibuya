# Remove obsolete linked actors and test garbage-collection liveness

Status: Accepted

Date: 2026-09-20

## Context

Shibuya's `Master` once owned a linked mailbox actor as well as the NQE supervisor and
metrics registry. After metrics operations moved to direct STM access, no internal code sent
messages to that actor. Its thread could therefore wait forever on an STM inbox with no live
writer.

The failure was reachability-sensitive. A caller that retained only `waitApp` could allow the
otherwise-unused master actor to become unreachable. A major garbage collection could then
raise `BlockedIndefinitelyOnSTM` in that linked actor, which surfaced to the caller as
`ExceptionInLinkedThread` even though every queue processor was healthy.

## Decision

Remove a linked actor when its wait source has no remaining sender and its responsibilities
have moved elsewhere. Do not keep it alive with an artificial root or an incidental reference.
The Shibuya master is a state handle containing the real NQE supervisor, metrics registry, and
failure-propagation policy; it is not a mailbox actor.

Treat reachability-sensitive liveness as a release property. The regression runs in a separate
Cabal test process, retains only the public `waitApp` action, forces major garbage collections,
and observes the application for a bounded interval. Process isolation lets the test exit
without a cleanup closure that would retain the application and invalidate the observation.
The normal core release command must select this garbage-collection suite together with the
ordinary lifecycle suite.

## Consequences

- `stopMaster` cancels the NQE supervisor, which remains the owner of processor children.
- Public application, metrics, shutdown, and failure-propagation interfaces remain unchanged.
- Future control protocols need a dedicated actor with live senders and explicit ownership;
  they must not revive an idle master mailbox for convenience.
- Tests for this class of bug must prove the pre-fix failure and must not keep the target alive
  through teardown state, weak-pointer cleanup assumptions, or a retained handle.

## Evidence

The implementation and failing-first evidence are recorded in
[`docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md`](../plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md).
Release `v0.9.0.2` contains the fix. The dedicated regression passes repeatedly on the fixed
tree and reproduces `ExceptionInLinkedThread ... thread blocked indefinitely in an STM
transaction` on the pre-fix tree.
