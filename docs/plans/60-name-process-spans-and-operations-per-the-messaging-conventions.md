---
id: 60
slug: name-process-spans-and-operations-per-the-messaging-conventions
title: "Name process spans and operations per the messaging conventions"
kind: exec-plan
created_at: 2026-11-12T03:24:05Z
intention: "intention_01m76tvgq9epqr5p2vdekeetxe"
master_plan: "docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T03:24:05Z
---

# Name process spans and operations per the messaging conventions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shibuya wraps the processing of each message, or each batch, in an OpenTelemetry span. Two
details of that span do not match the current OpenTelemetry messaging conventions. The span is
named `<destination> process` (for example `orders process`), while the conventions say the name
"SHOULD be `{messaging.operation.name} {destination}`" (`process orders`). And the span sets the
attribute `messaging.operation.type` but not `messaging.operation.name`, which the conventions
mark as Required.

After this change the span is named `process <destination>` and carries
`messaging.operation.name = "process"` alongside the existing `messaging.operation.type`.
Tools and dashboards built for the conventions then recognise Shibuya's spans without special
cases. Someone can see it by running the telemetry tests, or by opening a trace in the local
Jaeger and reading the span name.

This is a breaking change for anyone whose dashboards, alerts or sampling rules match the old
span name. It is done now because `shibuya-core` 0.13.0.0 is already a breaking release that
changes what tracing emits (see the parent MasterPlan), so users adjust once. It must not cost
anything per message: the name and the new attribute are per-processor constants.


## Progress

- [ ] M1: Processing and batch spans are named `process <destination>` and carry
  `messaging.operation.name = "process"`; telemetry tests are updated and pass with
  `cabal test shibuya-core`.
- [ ] M2: Performance gate passed against the baseline commit with no unexplained allocation
  change; retention suite passes.
- [ ] M3: User guide, capability document, changelog and the correlation ADR describe the new
  name with migration guidance; parent MasterPlan updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Rename without a compatibility switch.
  Rationale: A flag to keep the old name would have to be read on every span or threaded
  through configuration for a transition that users make once. The rename ships in a release
  that already changes trace shape, and the changelog gives the old and new names.
  Date: 2026-11-11

- Decision: The destination in the span name stays the processor identifier.
  Rationale: The name is built once per processor so that it costs nothing per message. The
  conventions take the destination from `messaging.destination.name`, which Shibuya sets to the
  processor identifier by default but which an adapter may override per message (the Kiroku
  adapter does). Following an overridden attribute would mean building a name per message. The
  mismatch for such adapters exists today and is documented rather than fixed here.
  Date: 2026-11-11

- Decision: Lifecycle span names are not changed.
  Rationale: `shibuya.ingest` and `<ProcessorId> shutdown` are Internal-kind spans about the
  processor's lifetime, not messaging operations; the messaging naming rule does not apply.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is a child of
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`. Prerequisite:
`docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md` is Complete; it
provides the benchmark group `tracing` in `shibuya-core-bench/bench/Bench/Tracing.hs` and the
test suite `shibuya-core-trace-retention-test`. The MasterPlan schedules this plan after
`docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`
and `docs/plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md`, because
all three edit the same telemetry code and documents and each performance gate should measure
one change. This plan does not use anything those two define; if they are not yet done, it can
still be implemented, but then they must be rebased over it.

Shibuya is a Haskell queue-processing framework; the library package is `shibuya-core`.

`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` holds the names. `processSpanName :: Text ->
Text` currently returns `destination <> " process"`, with a comment explaining that this order
followed the conventions as they stood when
`docs/plans/2-align-opentelemetry-semantic-conventions.md` was written. Attribute keys defined by
the conventions are taken from the generated module `OpenTelemetry.SemanticConventions` (package
`hs-opentelemetry-semantic-conventions`, bound `^>=1.40`), imported as `Sem`, through a small
`unkey` helper: for example `attrMessagingOperation = unkey Sem.messaging_operation_type`. That
generated module also defines `messaging_operation_name`.

The name is used in two places. In `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`,
`processUntilDrained` computes `spanName = processSpanName pidText` and a map
`constantFrameworkAttrs` (messaging system, destination name, operation type) once per
processor, and passes both to `processOne`, which runs per message and inserts the message
identifier into a copy of that map. In
`shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs`, `processCurrentBatchWithDetail`
calls `processSpanName pidText` and builds its own `frameworkAttrs` map per batch.

Tests that assert the name or attributes: `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`
(for example `hotName hot \`shouldBe\` "skip-proc process"`), and any other spec under
`shibuya-core/test/` that looks spans up by name; find them with
`grep -rn '" process\|process"' shibuya-core/test shibuya-metrics`. Documents that state the
name: `docs/user/opentelemetry.md` (the "Span name" subsection and the attribute table),
`docs/capabilities/opentelemetry-tracing.md`, `README.md`, and `docs/JAEGER_LOCAL_TESTING.md`.

What the OpenTelemetry messaging conventions say (the document
`docs/messaging/messaging-spans.md` in `open-telemetry/semantic-conventions`, status
Development, read in full on 2026-11-11): "The **span name** SHOULD be
`{messaging.operation.name} {destination}`"; `messaging.operation.name` has requirement level
Required; `messaging.operation.type` is Conditionally Required with the allowed values `create`,
`send`, `receive`, `process`, `settle`; a process span has kind `CONSUMER`. The operation name is
the system-specific name of the operation; Shibuya's is `process`.

Relevant ADRs.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md): the
framework owns the Consumer span, adapters contribute attributes that override framework
defaults of the same key, and disabled tracing does no per-message work.
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md):
an allocation increase is a regression even when time is within noise.
Plan 55 creates a correlation ADR (the next number after 0013); this plan adds the naming
decision to it if it exists, or records it in the changelog and this plan if it does not yet.

Performance. The span name remains a per-processor constant. Adding one key to
`constantFrameworkAttrs` makes that map four entries instead of three, and `processOne` copies
the map on its per-message insert, so the tracing-enabled path may allocate a few more bytes per
message. That is the only expected cost and it must be measured. The disabled path builds
neither the map copy nor the name per message and must not change.


## Plan of Work

### Milestone 1: the name and the attribute

In `Shibuya/Telemetry/Semantic.hs`, change `processSpanName` to return
`"process " <> destination` and rewrite its comment to cite the current rule. Add
`attrMessagingOperationName = unkey Sem.messaging_operation_name` and export it. Keep
`attrMessagingOperation` (the operation-type key) exported under its existing name so that
downstream code compiles; add a clearer alias only if it does not break exports.

Add the new key with the value `"process"` to `constantFrameworkAttrs` in `processUntilDrained`
and to `frameworkAttrs` in `processCurrentBatchWithDetail`. Do not add it inside `processOne`.
Adapter-supplied attributes continue to override framework defaults of the same key, so an
adapter may set a more specific operation name; nothing else changes.

Update `SemanticSpec.hs` and any other test that matches the old name, and add assertions that
single and batch spans carry `messaging.operation.name = "process"` and are named
`process <ProcessorId>`.

### Milestone 2: performance and retention gate

Compare the whole benchmark against a worktree of the commit before this plan's first commit, as
in Concrete Steps. Reading rule: every cell that runs with tracing disabled, and every
pre-existing group, shows no allocation change. Cells with tracing enabled may show a small
allocation increase from the larger attribute map; compute bytes per message, record it in
Surprises & Discoveries, and confirm it is consistent with one more map entry. A time
regression that fails `--fail-if-slower 10` after a confirming re-run with `--stdev 3`, or an
allocation increase larger than one map entry explains, stops the plan for a decision. If the
cost is judged too high, the alternative is to add the attribute to the span's creation
arguments as a shared constant map instead of the per-message map; try that before giving up
the attribute.

Run `cabal test shibuya-core`, which includes the retention suite; all suites must pass.

### Milestone 3: documentation

In `docs/user/opentelemetry.md`, rewrite the "Span name" subsection (`process <destination>`,
with the rule quoted, and the note that the destination is the processor identifier even when an
adapter overrides `messaging.destination.name`), add `messaging.operation.name` to the attribute
table, and fix every example that shows the old name. Update
`docs/capabilities/opentelemetry-tracing.md`, `README.md` and `docs/JAEGER_LOCAL_TESTING.md`
likewise. In the `0.13.0.0` entry of `shibuya-core/CHANGELOG.md`, add a breaking-change item
giving the old and new span names and a one-line migration note for queries and alerts (for
example, a Jaeger or Tempo search on operation name `orders process` becomes `process orders`).
Add the naming decision to the correlation ADR's conformance statement and remove span naming
and `messaging.operation.name` from its list of known gaps.

In the parent MasterPlan, mark this plan Complete and update Progress; with plans 55 and 56 also
Complete, the release gate becomes actionable.


## Concrete Steps

All commands run from the repository root inside the nix devShell.

```bash
nix fmt
cabal build all
cabal test shibuya-core
cabal test shibuya-metrics
grep -rn '" process\|process"' shibuya-core/test shibuya-metrics shibuya-example
```

The last command should show only the new form after Milestone 1.

Performance gate, where `<baseline-commit>` is the commit immediately before this plan's first
commit:

```bash
git worktree add /tmp/shibuya-tracing-baseline <baseline-commit>
( cd /tmp/shibuya-tracing-baseline && \
  cabal bench shibuya-core-bench \
    --benchmark-options="--stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv" )
cabal bench shibuya-core-bench \
  --benchmark-options="--stdev 5 --timeout 120 --baseline /tmp/shibuya-tracing-baseline.csv --fail-if-slower 10 --csv /tmp/shibuya-tracing-after.csv"
git worktree remove /tmp/shibuya-tracing-baseline
```

Seeing it in a trace backend: follow `docs/JAEGER_LOCAL_TESTING.md`, run
`cabal run shibuya-example`, and read the operation names in the Jaeger search form.

Expected:

```text
process orders
process payments
```


## Validation and Acceptance

A message processed by a processor with identifier `orders` yields a Consumer span named
`process orders` with `messaging.operation.name = "process"` and
`messaging.operation.type = "process"`; a batch from the same processor yields a batch span with
the same name and attributes. Before this plan the name is `orders process` and the
operation-name attribute is absent.

`cabal test shibuya-core` and `cabal test shibuya-metrics` pass.

The benchmark comparison exits 0, disabled cells and pre-existing groups show no allocation
change, and the enabled-path cost per message is recorded here with its explanation.

The changelog names the old and new span names.


## Idempotence and Recovery

All changes are ordinary source and documentation edits, repeatable and recoverable with git.
The benchmark worktree can be removed and recreated. Nothing is published by this plan; the
release happens once, as the parent MasterPlan describes.


## Interfaces and Dependencies

Prerequisite: plan 54 Complete. Scheduled after plans 55 and 56 by the parent MasterPlan.

No new package dependency; uses `OpenTelemetry.SemanticConventions.messaging_operation_name`
from `hs-opentelemetry-semantic-conventions` `^>=1.40`. Confirm the key exists in that series by
reading the package source (locate it with `mori registry show iand675/hs-opentelemetry --full`).

Changed in `Shibuya.Telemetry.Semantic`:

```haskell
-- | Span name for processing: @"process <destination>"@.
processSpanName :: Text -> Text

-- | The system-specific operation name (@messaging.operation.name@).
attrMessagingOperationName :: Text
```

Downstream effect, handled in the adapter plans under `docs/plans/` (57 Kafka, 58 PGMQ, 59
Kiroku): any adapter test, example or document that matches the old span name must change. One
is known: the PGMQ adapter's `ChaosSpec.hs` selects spans named `"dlq-identity process"`.
