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

Removing that actor did not remove the failure class. The remaining NQE supervisor was
started with `Supervisor.supervisor`, and NQE's `process` links every thread it starts to its
creator. A supervisor with a live child is reachable through that child, but once every
processor has finished, halted or failed it waits only on its mailbox, which is reachable
solely through the application handle. A caller that dropped the handle of a finished
application and kept running was killed at the next major collection in exactly the same way.
The same link also re-delivered every `StopAllOnFailure` failure that the per-processor link
had already delivered, so a caller handling the first exception could be killed by the second.

## Decision

Remove a linked actor when its wait source has no remaining sender and its responsibilities
have moved elsewhere. Do not keep it alive with an artificial root or an incidental reference.
The Shibuya master is a state handle containing the real NQE supervisor, metrics registry, and
failure-propagation policy; it is not a mailbox actor.

The rule covers the supervisor too. Never link a thread to a caller when the only thing that
can wake it is reachable solely through a handle the caller is free to drop. `startMaster`
therefore assembles the NQE `Process` from `newMailbox` and an unlinked async instead of
calling `Supervisor.supervisor`. Processor failures reach the caller only through the
per-processor links that `Supervised` installs when the strategy propagates failures, so one
failure produces exactly one exception.

Treat reachability-sensitive liveness as a release property. The regression runs in a separate
Cabal test process, retains only the public `waitApp` action, forces major garbage collections,
and observes the application for a bounded interval. Process isolation lets the test exit
without a cleanup closure that would retain the application and invalidate the observation.
The normal core release command must select this garbage-collection suite together with the
ordinary lifecycle suite.

## Consequences

- `stopMaster` cancels the NQE supervisor, which remains the owner of processor children.
- The supervisor runs unlinked. One with no children and no reachable handle is collected
  silently instead of being reported as a failure of the caller.
- Two process-isolated suites are both release gates, because each covers a state the other
  cannot: `shibuya-core-gc-test` exercises a supervisor kept reachable by a live idle child,
  and `shibuya-core-gc-finished-test` exercises one with no children after the handle is
  dropped. The first alone did not, and cannot, detect the second defect.
- Public application, metrics, shutdown, and failure-propagation interfaces remain unchanged.
- Future control protocols need a dedicated actor with live senders and explicit ownership;
  they must not revive an idle master mailbox for convenience.
- Tests for this class of bug must prove the pre-fix failure and must not keep the target alive
  through teardown state, weak-pointer cleanup assumptions, or a retained handle.

## Evidence

The implementation and failing-first evidence are recorded in
[`docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md`](../plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md).
Release `v0.9.0.2` contains that fix. The dedicated regression passes repeatedly on the fixed
tree and reproduces `ExceptionInLinkedThread ... thread blocked indefinitely in an STM
transaction` on the pre-fix tree.

The supervisor amendment, dated 2026-09-20, is recorded in
[`docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md`](../plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md)
and was found by the independent review
[`docs/reviews/REV-16-childless-supervisor-gc-residual.md`](../reviews/REV-16-childless-supervisor-gc-residual.md).
Before the change the finished-application suite reports the caller killed in all three of its
scenarios and the lifecycle case "StopAllOnFailure delivers one processor failure to the
caller exactly once" counts two deliveries; after it both pass, together with the unchanged
propagation, isolation, halt and shutdown cases.
