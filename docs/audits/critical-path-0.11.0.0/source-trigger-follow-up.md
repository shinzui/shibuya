# Source trigger and ordinary-runtime investigation

The combined ordinary-Haskell startup handoff passes all eight focused cases
and the unchanged full 62-case release gate. It uses no private GHC primitive.
The original source trigger and the intervening failed experiments are recorded
below; final correctness validation is recorded at the end.

## Saved workaround and scope

The custom GHC fork primitive and its passing results are preserved at commit
`721436c` on `perf/serial-intake-fork-workaround`. They are not on `master`.
The user prefers avoiding that maintenance cost. This investigation starts from
`20c0821`, retains the single-transaction intake repair, and uses ordinary GHC
forking. The existing workloads, compiler, dependency graph and release gate
remain fixed. Diagnostics are separate from gate results.

## Confirmed minimal source trigger

The first control compares the immutable release runtime against that same
runtime with only the no-op tracer/provider sharing change. Both use GHC 9.12.4,
225 identical nonlocal dependency unit IDs, the current benchmark harness and
default RTS settings. Each runs the existing counter-100 with
`--stdev 3 --timeout 120`. The order is fresh/shared/shared/fresh; both sides
receive identical arguments without a baseline option.

| Build pair | Fresh 1 µs | Shared 1 µs | Shared 2 µs | Fresh 2 µs |
| --- | ---: | ---: | ---: | ---: |
| Previously archived binaries | 43.03 | 58.09 | 58.64 | 38.13 |
| Rebuilt with compiler dumps | 45.17 | 58.55 | 58.13 | 42.59 |

The sharing change is sufficient to reproduce the short-counter regression on
the release runtime, in both orders and both builds. It first appeared in
`fcd03b5` and is present in the restored telemetry implementation. No GHC upgrade
is involved. This does not establish that reverting it alone repairs current
code: the retained queue optimization changes the allocation pattern too, and
earlier full-workload rollback attempts did not pass.

The rebuilt pair's Supervised module has identical optimized Core and Cmm.
Bench.Handler's processing action is also unchanged in Core. Its changed entry
calls are the fresh provider worker with a boxed effect environment versus an
inlined static-effect runner with unboxed environment fields. Thus there is no
new processor-loop instruction sequence in this minimal pair. Tracing setup
removes allocation and changes the entry boundary before the concurrent work.

## Scheduling sequence, beyond migration totals

GHC's fork sets a rescheduling hint. Blocking a thread does not clear it; yielding
does. Consequently, when the consumer blocks on an empty inbox, its producer can
inherit the pending hint and honor it at a later nursery-block transition.

These implementation details were inspected in `mori://ghc/ghc`,
project-relative `rts/PrimOps.cmm`, `rts/Schedule.c` and
`rts/HeapStackCheck.cmm` at `ghc-9.12.4-release` (artifact-level source URIs
pending). In particular, `scheduleHandleThreadBlocked` does not reset the hint,
whereas `scheduleHandleYield` does.

Reanalysis of the existing minimal-pair event logs distinguishes whether the
producer's first yield happens before or after its first consumer wake request,
restricted to invocations where the consumer's first post-fork stop is an STM
block. Percentages below use all invocations as the denominator.

| Sequence | Fresh provider | Shared provider |
| --- | ---: | ---: |
| Producer yields before first consumer wake request | 79.86% | 36.05% |
| Consumer wake request precedes producer's first yield | 10.57% | 40.07% |
| Consumer migration per invocation in the first group | 0.0003 | 0.0004 |
| Consumer migration per invocation in the second group | 0.9809 | 0.9861 |

The captures contain 131,071 fresh and 65,535 shared invocations. Equal
timestamps are resolved using recorded event order only on the same capability;
cross-capability ties are not assigned an order. Wake events are wake requests,
not proof of immediate execution. The classification leaves parent-first yields,
overflows and cases with no child yield in separate groups.

This identifies the expensive ordering: the producer yields after it has made
the consumer eligible to run, allowing both to be distributed across capabilities.
The source change increases that ordering substantially. The exact byte offset
of the nursery boundary has not been measured; the evidence does not require
claiming a precise allocation-address explanation.

## Predicted ordinary Haskell intervention

The next candidate changes only serial single-message intake: call the standard
`Control.Concurrent.yield` before entering its source/unlift, inside the existing
`finally` scope. This honors the startup scheduling request before publishing any
message that could wake the consumer. It retains ordinary forking, preemption,
migration, source ownership and cancellation. There is no private primitive,
dependency change, affinity, artificial allocation or extra readiness wait.

Prediction recorded before measurement: wake-before-first-child-yield cases
should collapse, reducing consumer migration. Parent post-fork yields can remain;
the intervention need not eliminate all migration. Check the existing eight
focused cases first, then the unchanged full release gate if they pass. Check
event ordering separately after timing runs. No performance success is claimed
until these results complete.

### Early yield alone: partial mechanism repair, rejected as a complete fix

The eight focused cases passed. The first full run passed 60/62: only unchanged
Streamly fold controls failed (11% and 13%). Those controls passed paired reruns
at −0.1% and +0.3%. A second full run with identical binaries then failed five
cases, including counter-100 (+23%), counter-1000 (+12%) and counter-10000
(+24%). These failures are retained; the first favorable counter result is not
treated as a reliable repair.

Separate event captures verify that the intended mechanism changed: consumer
migrations fell from 0.2216 to 0.00085 per invocation. However, producer
migrations remained high (0.3869 -> 0.4226), and the consumer's first post-fork
stop was a yield in 41.8% of candidate invocations. Early producer yield fixes
the later wake-before-yield ordering while leaving the consumer's initial
allocation-before-blocking opportunity for migration open.

### Next prediction: complete the startup handoff

Combine early producer yield with an immediate consumer wait for inbox data or
source completion, before allocating processor state. The wait observes
readiness without removing a message, runs unmasked inside existing `withAsync`
ownership, and wakes on source completion/failure. It changes neither admission
capacity nor source/handler ownership. This specifically targets the remaining
consumer-first yield and producer migration. The earlier readiness-only attempt
did not address the hint inherited by the producer; this candidate addresses
both measured opportunities. It remains an experiment until the unchanged
focused/full gate and correctness checks pass; the following section records
their subsequent completion.

## Combined handoff result

The combined candidate passed all eight focused cases, with counter-100 at
40.5 µs versus release 43.9 µs. Separate event captures support both predicted
changes: the consumer's first post-fork yield falls from 34.5% to 15.8%; consumer
migrations fall from 0.2128 to 0.00092 per invocation, and producer migrations
from 0.3864 to 0.1625. These are reductions, not a claim of eliminating migration.

The formatted final build then passed **all 62 existing release comparisons**
using the unchanged `--stdev 5 --timeout 120 --fail-if-slower 10` workflow.
Release and candidate completed in 126.34 and 107.81 seconds respectively. All
225 nonlocal dependency unit IDs match. The event-capture candidate and final
build have identical Haskell source; the final executable was also checked for
absence of the private fork primitive.

| Existing case | Release µs | Combined handoff µs | Change |
| --- | ---: | ---: | ---: |
| counter-100 | 41.32 | 38.16 | −7.7% |
| counter-1000 | 421.53 | 342.63 | −18.7% |
| counter-10000 | 4357.98 | 4366.24 | +0.2% |
| runWithMetrics-100 | 46.15 | 32.30 | −30.0% |
| runWithMetrics-1000 | 361.15 | 256.14 | −29.1% |
| runWithMetrics-10000 | 4133.70 | 3368.69 | −18.5% |
| cpu-bound-serial / 1000-msgs | 415.07 | 339.49 | −18.2% |
| cpu-bound-serial / 10000-msgs | 4208.75 | 3508.86 | −16.6% |

The production change uses `Control.Concurrent.yield` and existing STM inbox
operations. There is no Cmm, FFI, affinity, compiler guard, dependency-bound
change or license change. It applies only to serial single-message intake;
concurrent and batch startup behavior is preserved. The original fork primitive
workaround remains isolated on its saved branch and is not merged.

All **289 core examples, 104 metrics examples, and both isolated GC suites**
pass on this implementation. The two added state/ownership examples cover the
single-message and batch runners. Existing coverage exercises source failure
before output, idle/paused-source cancellation, handler/finalizer masking,
terminal wakeups and collection of running and finished applications.
Formatting and diff checks pass. No further benchmark profiles or acceptance
thresholds were introduced.

## Artifacts

Controls, compiler dumps/diffs, predictions and event-order analysis are retained
in `/tmp/shibuya-source-trigger`. The minimal source patch and original binaries
are in `/tmp/shibuya-counter-rootcause-5zo0_ypk`. The ordinary Haskell candidate,
dependency plan, source patch, binary hashes and focused results are in
`/tmp/shibuya-intake-start-yield`. Measurements run without concurrent builds,
tests or event parsing; the workstation is not exclusively reserved.
The combined startup candidate is isolated in `/tmp/shibuya-intake-ordered-start`.

- [source-trigger-measurements.json](source-trigger-measurements.json) retains
  both minimal-source controls, compiler checks, event-order classifications,
  every early-yield-only result including failures, and the combined candidate's
  focused/full results, hashes and validation.
- [fork-event-order.py](fork-event-order.py) records the event-order classifier.
- [provider-entry-core.diff](provider-entry-core.diff) shows the changed tracing
  entry boundary while leaving the benchmark processing action unchanged.
