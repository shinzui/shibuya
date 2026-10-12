---
id: 9
slug: audit-and-improve-opentelemetry-api
title: "Audit and improve Shibuya's OpenTelemetry API for adapters"
kind: exec-plan
created_at: 2026-05-05T22:19:16Z
intention: "intention_01kh0akd82ekat0be54p2f72kv"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-12T23:33:00Z
      mode: "update"
      note: "Consolidate audit findings into plan 9 and reconcile implemented, superseded, and remaining work against current core and adapter sources."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-12T23:33:00Z
      verdict: "comments"
      note: "Verified F1-F8 against three source trees; dead config resolved, F6/F7 compatibility decisions and F8 implementation remain, and enabled DLQ identity proof is missing."
---

# Audit and improve Shibuya's OpenTelemetry API for adapters


This living ExecPlan follows `agents/skills/exec-plan/PLANS.md`. It contains the
original eight audit findings, their implementation evidence, and the remaining
work. The former companion findings document has been consolidated here so that
there is one plan with ID 9. Historical evidence is explicitly dated; it is not a
claim that the current checkout passed the same gates.


## Purpose / Big Picture


Shibuya processes queued messages under supervision. OpenTelemetry (OTel) records
named, timed operations called spans; spans share a trace ID and identify their
parent so an operator can follow a message from producer through consumer and
onward to a dead-letter queue (DLQ), which stores messages a handler cannot process.

This audit covers four boundaries: the public `Tracing` effect (A), ownership and
attributes of per-message spans (B), incoming parent-context propagation (C), and
outgoing producer/DLQ propagation (D). The aim is one framework-owned Consumer span
per individually processed message, enriched by the adapter, with usable parent
links and predictable disabled-tracing behavior. Batch tracing is not assessed by
this audit's per-message acceptance tests.

The 2026-10-12 review confirms F1/F2/F3/F5 implementations. F4's dead configuration
was removed by a later API cleanup; the proposed convenience helper was never
implemented. F6 and F8 remain open. F7's allocation was improved, but its disabled
callback still receives a span with zero IDs. The most consequential outstanding
validation is a tracing-enabled PostgreSQL DLQ test. This update changes documents,
not runtime code.


## Progress


- [x] (2026-05-05) M1 — Audited the framework and both adapters; recorded F1–F8 and mapped the original S1–S7 hypotheses. Audit commit `8234f1a`.
- [x] (2026-05-05; source rechecked 2026-10-12) M2.1 — F1/F2 core fix: strict `Envelope.attributes :: HashMap Text Attribute`, explicit adapter-over-default merge, and a one-span in-memory regression test. Commit `7c6586b`.
- [x] (2026-05-05; source rechecked 2026-10-12) M2.2 — PGMQ migration adds the empty attribute map. `mori://shinzui/shibuya-pgmq-adapter` commit `274c0eb` (commit artifact URI pending).
- [x] (2026-05-05; source rechecked 2026-10-12) M2.3 — Kafka contributes typed attributes during conversion; duplicate tracing wrapper and its test removed. `mori://shinzui/shibuya-kafka-adapter` commit `0440544` (commit artifact URI pending). Its current OTel demo uses `runApp`.
- [x] (2026-05-05; source rechecked 2026-10-12) M3.1 — F3/F5: core `currentTraceHeaders` (`193de1d`) and PGMQ DLQ header merge (`mori://shinzui/shibuya-pgmq-adapter`, commit `274c0eb`; commit artifact URI pending).
- [x] (2026-05-05, historical evidence) M4 — Refreshed the then-current integration document (`d5024b1`) and recorded build/test/Jaeger results below. This does not close deferred findings or prove a tracing-enabled DLQ round trip.
- [x] (2026-07-02; verified 2026-10-12) F4 dead-config remedy — Plan 25 removed `TracingConfig` and corrected the umbrella-module example (`a96ad52`). Caller-managed tracing remains the supported contract.
- [x] (2026-07-02; verified 2026-10-12) F7 allocation improvement — Plan 26 hoisted the disabled span into a shared constant (`8e55ab4`); zero-ID callback semantics remain.
- [x] (2026-10-12) Reviewed both former documents against all three working trees; consolidated findings into this plan, corrected current paths/interfaces, and updated inbound references.
- [ ] M3.1 validation remainder — Add an enabled-tracing PostgreSQL test proving the DLQ header identifies the failing consumer span, including direct-queue and topic-route delivery. Preserve the existing disabled-tracing test.
- [ ] F6 — Resolve provider allocation on every `runTracingNoop` invocation while accounting for the public `getTracer` contract; this is startup overhead, not the per-message allocation fixed by plan 26.
- [ ] F7 — Decide and implement an explicit disabled-span API contract, or formally accept/document the invalid-ID sentinel. The proposed `Maybe Span` callback has not landed.
- [ ] F8 — Add and verify ingester-lifetime and adapter-shutdown trace coverage while preserving cancellation, timeout, and failure behavior.
- [ ] Documentation follow-up — Correct the OTel 1.0 provider-shutdown example in `docs/user/opentelemetry.md`; then record updated acceptance for any remaining implementation work. A managed tracing helper is optional, not a prerequisite for closing the removed dead-config defect.


## Surprises & Discoveries


### Original hypotheses and their disposition


S1 (no-op provider allocation) became F6. S2 (duplicate Consumer spans) became F1,
with an important correction: the old Kafka wrapper reattached the original parent
context, so the spans were siblings, not nested. S3 (attributes split across spans)
became F2. S4 (no symmetric PGMQ `traced` module) was refuted as a separate defect:
adapters need to contribute context and attributes, not open a second process span.
The DLQ concern within S4 became F3. S5 (dead config/provider wiring) became F4.
S6 (dummy span IDs) became F7. S7 (no convenient active-span injection helper) became
F3/F5. F8 was identified while reading the ingester and shutdown paths.

### Implementation discoveries retained from 2026-05-05


Adding OTel `Attribute` values prevented deriving `NFData` for `Envelope`. The
manual instance in `shibuya-core/src/Shibuya/Core/Types.hs:162` forces the other
fields deeply and the attribute map only to weak head normal form (the outer
constructor). The old plan overstated this as equivalent to deeply forcing every
attribute; it is not a general guarantee, particularly for collection values.

Sequentially adding framework defaults and adapter attributes originally failed
the override test. The implementation assembles a single map using left-biased
`HashMap.union envelope.attributes frameworkAttrs`, then calls `addAttributes`
once. This makes precedence explicit without depending on the SDK's repeated-write
behavior. The original root cause was not established, so it remains a historical
observation, not an assertion about current SDK merge semantics.

The initial prohibition on all local dependency overrides was relaxed during the
adapter migrations: gitignored development overrides were allowed, while release
verification used published packages. Do not repeat the obsolete instruction to
wait for the original 0.5.0.0 publication before inspecting these fixes.

### Review discoveries on 2026-10-12


The findings table still said F3/F5 were open and adapter migration awaited
publication, despite the main plan recording completed commits. Both code paths
remain present. Later work moved runners to `Shibuya.Internal.Runner.*`, changed
`runApp` to take `AppConfig`, removed `Shibuya.Telemetry.Config`, and upgraded OTel.
The old instructions referenced deleted source modules and obsolete signatures.

F4's proposed bracket returned an `AppHandle` immediately after `runApp`. Since
`runApp` starts asynchronous processors and returns immediately, a provider bracket
around that call alone would shut tracing down while the application was still
running. Any future convenience helper must scope the entire application lifetime,
including waiting, stopping, and exceptional cleanup. It must not revive the removed
configuration type without revisiting plan 25's explicit decision.

F6's original proposal also missed `getTracer`: it is public, returns a concrete
`Tracer`, and is exercised in `EffectSpec`. Replacing the stored tracer with
`Nothing` requires a deliberate compatibility design. F7's zero IDs are invalid
trace-context sentinels; they are not valid W3C IDs. `PropagationSpec` explicitly
tests rejection of zero trace/span IDs.

The existing PGMQ database test called “preserves trace headers when moving to DLQ”
runs under `runTracingNoop`. It proves original-header preservation only. The core
`currentTraceHeaders` active-span test checks header presence but does not compare
the encoded span ID with an exported span. Neither replaces the missing runtime
consumer-to-DLQ identity assertion.

The legacy integration documents were removed in `3fcfb36` after archival. Current
implementation instructions therefore point to `docs/user/opentelemetry.md` and
real source/tests; historical document contents remain in Git history. Both original
ID-9 documents lacked provenance, so their original model attribution is unknown.


## Decision Log


On 2026-05-05, the audit was deliberately written before code changes and treated
core and adapters as one target: the defects crossed repository boundaries. It
separated API ergonomics, span ownership, incoming context, and outgoing context
rather than treating all tracing concerns as one feature. F1/F2 were implemented
together, F3 followed, and F5 accompanied its propagation helper. F4/F6/F7/F8 were
left for later work.

On 2026-05-05, the attribute hook was chosen over documenting `traced` as mutually
exclusive with `runApp`, or detecting an existing span by name. The framework owns
the process span; the adapter supplies data. The field is a strict, non-optional
`HashMap Text Attribute` with `mempty` as its default. A single left-biased merge
makes adapter overrides explicit. The Kafka wrapper was deleted rather than retained
as a second way to open a process span.

On 2026-05-05, PGMQ DLQ propagation chose the consumer's context for active
`traceparent`/`tracestate` headers, retaining replaced producer headers under
`x-shibuya-upstream-*`. With tracing disabled or no active span, original headers
pass through. The implementation uses the same merge before either DLQ route.
`injectTraceContext` remains the lower-level primitive; `currentTraceHeaders` is the
recommended helper when an adapter does not already hold a span handle.

On 2026-05-05, local development overrides were permitted when gitignored; release
checks still used published dependencies. This supersedes the earlier decision to
block all adapter work until publication.

On 2026-10-12, the review adopted plan 25's existing F4 resolution: remove the dead
config and let callers choose `runTracing` or `runTracingNoop`. A convenience helper
is an optional future design, not missing implementation of that resolution. The
review retains F6/F7/F8 and the DLQ integration-test gap as open, without implementing
them in this documentation task or silently treating deferral as completion.

On 2026-10-12, at the user's request, the findings companion was folded into this
file, keeping ID, slug, intention, and the surviving plan's creation timestamp. All
F1–F8 IDs remain stable. Inbound references now target this plan; no replacement
number or second plan identity is introduced.


## Outcomes & Retrospective


### Verified implementation state


The audit and the highest-priority span-ownership changes landed. Core commit
`7c6586b` supplies the hook; Kafka conversion supplies system/partition/offset;
PGMQ supplies an empty map; core tests verify one exported span and adapter override
precedence. Core `193de1d` and the PGMQ migration supply outgoing consumer context.
F1/F2/F3/F5 therefore need no repeat implementation. F3 needs stronger integration
proof. F4's misleading config was removed by `a96ad52`; a new lifecycle helper was
not delivered and is not implied by that deletion. F6/F8 remain unimplemented.
F7 still exposes zero IDs despite the shared-span improvement in `8e55ab4`.

The reviewed clean source baselines were this repository at
`3fcfb367994fbf200d76f47b932882bdf10227db`,
`mori://shinzui/shibuya-pgmq-adapter` at commit
`c443ac349ad5d75c4820a1688e5bd34d8911f136`, and
`mori://shinzui/shibuya-kafka-adapter` at commit
`c04758990927bbda6d0616ae9609c263ec73758b` (commit artifact URIs pending).
Observed checkout versions were core 0.10.0.1, PGMQ adapter 0.16.1.0, and Kafka
adapter 0.9.1.0. These are source observations, not claims about latest releases.

### Historical acceptance, retained without reasserting it


The 2026-05-05 main plan recorded core 116/116, PGMQ 125/125, and Kafka 26/26 tests,
plus builds and flake checks, as passing. It recorded a Kafka Jaeger trace
`8754d1c69c6577bbe7a6595293c77dde` containing producer `shibuya.send.message` and one
`orders process` Consumer span, parented to `5e9480617881e53d`, with system `kafka`,
partition 0, and offset 3. It also recorded five PGMQ messages with a representative
producer → publish → process → delete shape. That PGMQ smoke exercised successful
consumption, not enabled-tracing DLQ forwarding.

The adapter migration plans later recorded publication of their 0.5.0.0 packages
and verification against published core, superseding this plan's old
“publication pending” note. This review does not perform a release audit. The
adapter plans' older smoke-status prose is not fully synchronized with the main
plan's recorded transcript, so those historical claims are not promoted to fresh
runtime proof here.

### Validation in this review


The focused core telemetry run passed: 28 examples, 0 failures. It includes
no-op effect operations, propagation parsing, `currentTraceHeaders`, and the
one-span/adapter-attribute regression. The PGMQ merge run passed all six examples
after explicitly enabling test suites. Kafka's conversion run passed all 22 tests
inside its development shell; the first attempt from the inherited shell failed
to link `librdkafka`, before tests ran. The commands are in Concrete Steps.

```text
Core telemetry: 28 examples, 0 failures
PGMQ mergeDlqHeaders: 6 examples, 0 failures
Kafka Convert: All 22 tests passed
```

Document checks passed for whitespace, the single surviving ID-9 file, language-tagged
fences, local Markdown links, and removal of companion-file references from this
repository and both adapter documentation trees. No new PostgreSQL/Redpanda/Jaeger
smoke, full multi-repository test matrix, performance benchmark, or release gate
is claimed by this documentation update.


## Context and Orientation


Core lives in this repository. `shibuya-core/src/Shibuya/Core/Types.hs` owns
`Envelope`, the message metadata plus payload. `traceContext` carries incoming
W3C headers (trace and parent IDs); `attributes` carries adapter-specific data for
the framework span. `shibuya-core/src/Shibuya/Telemetry/Effect.hs` owns the static
`Tracing` effect and enabled/disabled runners. A static effect is effectful's
mechanism for making a tracer available to functions via an `Eff` effect stack.
`Propagation.hs` extracts/injects headers. `Semantic.hs` owns wire keys and names.
The umbrella `shibuya-core/src/Shibuya/Telemetry.hs` re-exports those three modules.
There is no Config module now.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` owns `processOne`, which
extracts the parent, opens the process span, merges attributes, runs the handler
and framework-owned finalization, and records results. An `AckDecision` is the
handler's verdict, such as acknowledge, retry, dead-letter, or halt; the adapter's
acknowledgement handle applies that verdict to the broker.
`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs` streams messages into bounded
inboxes. `shibuya-core/src/Shibuya/App.hs` starts processors and owns graceful
shutdown. Both single-message and batch startup paths use the ingester.

The adapters are `mori://shinzui/shibuya-pgmq-adapter` and
`mori://shinzui/shibuya-kafka-adapter`. Resolve their checkout roots with
`mori registry show <qualified-project> --full`; commands below run from those
roots. In cross-repository source citations below, a canonical project URI is
paired with its project-relative path and line. Source-file artifact URI coverage
is pending. Migration history is in
`mori://shinzui/shibuya-pgmq-adapter/plans/1-migrate-to-shibuya-core-0.5-and-dlq-trace`
and `mori://shinzui/shibuya-kafka-adapter/plans/12-migrate-to-shibuya-core-0.5`.
The registry did not resolve these plan artifact URIs during this review; their
files were verified in the registered checkouts.

Relevant local context is [plan 25](25-pre-1-0-public-api-cleanup.md), which removes
the redundant configuration path, [plan 26](26-reduce-per-message-hot-path-overhead.md),
which hoists tracing constants, and [plan 10](10-upgrade-to-hs-opentelemetry-1-0.md),
which upgrades the SDK-facing code. No dedicated OTel ADR was found in the local
ADR heading scan. [ADR 3](../adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md)
requires explicit failure outcomes, unconditional master cleanup, bounded graceful
shutdown, and once-only adapter shutdown. F8 must preserve these guarantees.


## Plan of Work


### Finding F1 — Duplicate Consumer spans (B, original P0): implemented


The old Kafka `traced` wrapper opened a second span around finalization and
reattached the incoming producer context. A user combining it with `runApp` got
sibling Consumer spans instead of one process operation. The fix is present in
`shibuya-core/src/Shibuya/Core/Types.hs:140` and
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs:680`: the framework owns the
span and merges envelope attributes once, with adapter keys taking precedence.
`shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs:101` exercises one message and
requires exactly one exported span.

In `mori://shinzui/shibuya-kafka-adapter`,
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs:69` supplies the map;
`Shibuya.Adapter.Kafka.Tracing` and `TracingTest` are absent from source and Cabal
module lists. `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs:89` brackets the provider
and now runs the finite source through `runApp`/`waitApp`. The historical alternatives
(mutual-exclusion documentation or guessing whether a matching span already exists)
were rejected because they retain ambiguous span ownership. No further F1 code is
needed; preserve the one-span regression.


### Finding F2 — Kafka attributes on the wrong span (B, original P1): implemented


F2 shared F1's fix. In `mori://shinzui/shibuya-kafka-adapter`,
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs:81` constructs
`messaging.system="kafka"` and typed integer partition/offset attributes;
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs:100` tests them.
The core semantic test verifies those values override defaults on its sole span.
The current operation key is `messaging.operation.type`, not the original audit's
`messaging.operation`. In `mori://shinzui/shibuya-pgmq-adapter`,
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs:126` supplies an empty map,
so framework defaults apply. No symmetric PGMQ tracing wrapper is missing.


### Finding F3 — DLQ forwards the original parent (D, original P1): implemented; integration proof open


The original defect forwarded the producer header rather than injecting the
failing consumer span. This omitted the consumer from the DLQ message's parent
chain; it did not necessarily create a different trace ID. Core
`shibuya-core/src/Shibuya/Telemetry/Propagation.hs:82` now obtains active context.
In `mori://shinzui/shibuya-pgmq-adapter`,
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:283` calls it before
`deadLetterTransactionally`. Both direct-queue and topic-route sends consume the
merged headers. `mergeDlqHeaders` at line 385 replaces active context, saves
upstream values under `x-shibuya-upstream-*`, preserves other fields, and forwards
original headers unchanged when no consumer context exists.

`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs:403` in that same
canonical project has six current merge cases (five original plus a later non-UTF8
case). `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs:337` tests the
no-op fallback against the database. The remaining enabled-tracing test is defined
in milestone M3.1V below. It is a validation gap, not an absent merge implementation.


### Finding F4 — Dead config and provider lifecycle (A, original P1): dead config resolved; helper not implemented


Plan 25 deliberately removed `TracingConfig` rather than wiring it into an exporter
configuration path already served by `OTEL_*` and the choice of runner. Source
`shibuya-core/src/Shibuya/App.hs:209` still requires `Tracing :> es`; callers own the
provider lifetime. There is no `runAppTraced` or `withTracing` helper. The original
helper proposal is superseded as a required fix, and its handle-returning bracket
would have been too short-lived.

An optional future helper must keep the provider alive through processor completion
and shutdown, and test success, startup failure, exception, and cancellation. Keep
this separate from the remaining documentation correction: the Quick Start in
`docs/user/opentelemetry.md:20` still passes `shutdownTracerProvider` to `bracket`
without supplying the timeout argument required by the current API. The Kafka demo
uses the current explicit `Just 5_000_000` timeout. Update that guide with a tested
full-lifetime example; do not reintroduce `TracingConfig` merely to match old prose.


### Finding F5 — No convenient active-context injection (D, original P2): implemented


`shibuya-core/src/Shibuya/Telemetry/Propagation.hs:77` exposes
`currentTraceHeaders :: (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`.
It returns `Nothing` with tracing disabled or no active span, otherwise calls the
retained `injectTraceContext`. PGMQ consumes it in the actual DLQ path, so the
original claim that adapters never exercise injection is obsolete. Haddocks explain
both APIs. `PropagationSpec` covers the three branches; exact active-span identity
should be strengthened as part of M3.1V.


### Finding F6 — No-op provider allocation (A, P2): open


`shibuya-core/src/Shibuya/Telemetry/Effect.hs:103` still calls
`createTracerProvider [] emptyTracerProviderOptions` for every `runTracingNoop`.
The stored representation retains a strict `Tracer` even though guarded span
operations skip it. This is per runner invocation, not per message. No measured
startup-cost claim is made here. Plan 26's constant hoisting did not remove it.

The proposed optional-tracer representation has not landed. Before implementing
it, settle how `getTracer` (`Effect.hs:245`) continues to supply a concrete tracer
under no-op mode; `EffectSpec` already exercises that contract. An unannounced
change to `Maybe Tracer`, an exception, or an undefined value is not an acceptable
internal optimization. Record the chosen compatibility approach and demonstrate
unchanged no-op action results and `getTracer` behavior, plus removal of repeated
provider construction. This finding remains a design-and-implementation backlog
item rather than a ready-to-apply signature change.


### Finding F7 — Disabled callback exposes zero IDs (A, P2): partially improved; contract open


`shibuya-core/src/Shibuya/Telemetry/Effect.hs:159` calls `f dummySpan` when disabled.
The value at line 294 is now a shared `NOINLINE` constant wrapping a zero-ID
`SpanContext`, not a freshly built full span on each callback. The callback type
remains `Span -> Eff es a`; the proposed `Maybe Span` change never landed.

The remaining concern is callers inspecting or injecting that invalid sentinel
for correlation. `currentTraceHeaders` already guards disabled mode. A future
resolution must choose explicit documentation/acceptance of the sentinel or an
API that represents absence; an additive helper can avoid forcing an immediate
breaking change. Do not claim a breaking signature change is the only possible
fix. Cover inspection/injection behavior and retain enabled-span behavior before
marking this contract resolved.


### Finding F8 — No framework ingestion/shutdown spans (B, P2): open


`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs:53` folds the source with
metrics and pause support but has no tracing constraint or span.
`shibuya-core/src/Shibuya/App.hs:363` coordinates shutdown, and its adapter calls
at line 413 have no spans. `ingestSpanName` remains unused by the runner. This
finding concerns framework-owned spans; underlying broker instrumentation and
lifecycle metrics may still provide information. The old statement that failures
are visible only in logs is obsolete after lifecycle observability work.

The proposed implementation is an Internal-kind span for each source-stream
lifetime, plus a separate Internal span per adapter shutdown attempt. Avoid adding
an extra per-message ingestion span. Ensure recorded exceptions and status survive
failure/cancellation, do not mask the original failure, and preserve ADR 3's
shutdown semantics. Account for both single-message and batch ingester call sites.
The shutdown API currently requires only `IOE`, so adding `Tracing` requires an
explicit compatibility decision. Long-lived spans are normally exported on end;
this proposal alone does not promise live visibility of an operation that never
finishes.


### Milestones and remaining execution order


M1 (audit) and M2 (F1/F2 plus both adapter migrations) are complete. M2 acceptance
is a single exported process span with the union of framework/adapter attributes,
not just successful compilation. Retain the core semantic test and adapter
conversion tests when changing these paths.

M3.1V is the next concrete validation milestone. In the PGMQ project's
`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs`, add an in-memory
exporter around a real `runApp` consumer whose handler dead-letters a message with
a known producer context. Wait for finalization and stop the app while the provider
is alive. Read the DLQ row and the exported process span; decode the active header
and compare both trace ID and span ID with that span. Check the stashed producer
header and custom headers. Exercise direct-queue and topic-route delivery, and a
message with no original headers. Preserve the separate no-op test. Add the
exporter/API dependencies to the adapter test stanza if required, using Mori and
registry/upstream release verification before selecting bounds. Strengthen core
`PropagationSpec` to compare the header against the active exported span as well.
Acceptance is equality of IDs, not simply the presence of a `traceparent` string.

M3.2 addresses F8 using the files and constraints above. Add in-memory exporter
tests for a finite source, a source exception, normal adapter shutdown, and a
shutdown exception/timeout. Assert span kind, processor identity, error event and
status, once-only shutdown, preserved thrown failures, and zero exported spans
under no-op mode. Run existing lifecycle tests to guard the cancellation contract.
This milestone does not depend on inventing a managed tracing helper.

M3.3 resolves F6/F7's compatibility choices before changing their public behavior.
Record the selected API and release implications here, then update EffectSpec and
consumer call sites as necessary. Their original sketches are not settled public
signatures. Each finding may be formally accepted as a documented trade-off, but
must not be checked off solely because the old code still compiles.

M4 follow-up updates the current user guide and this plan after those milestones.
Record exact validation results and limits, and distill any new durable ownership
or API decisions into the ADR corpus following `agents/skills/exec-plan/ADR.md`.
Do not recreate the deleted legacy integration plans to satisfy the original M4
instructions. A separately scoped managed-provider helper or Kafka DLQ producer is
not silently added to this audit's remaining implementation.


## Concrete Steps


Run core commands from the repository root. These checks select the relevant
existing tests and need no live broker:

```bash
cabal test shibuya-core-test --test-options='--match Shibuya.Telemetry' --test-show-details=direct
```

Discover the adapter roots before running their commands:

```bash
mori registry show shinzui/shibuya-pgmq-adapter --full
mori registry show shinzui/shibuya-kafka-adapter --full
```

From the PGMQ checkout root, select the pure merge tests; `--enable-tests` avoids
a solver plan that omits the suite. Successful output must name six merge cases.

```bash
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='--match mergeDlqHeaders' --test-show-details=direct
```

From the Kafka checkout root, use its development shell for native librdkafka:

```bash
nix develop -c cabal test shibuya-kafka-adapter-test --test-options='--pattern Convert' --test-show-details=direct
```

For actual runtime implementation, additionally run `cabal build all`, the affected
full test suites, `nix fmt`, and `nix flake check` in each changed repository.
PostgreSQL/Redpanda integration suites require their repository's documented local
services; a broker-free filter is not a substitute for M3.1V. New enabled-tracing
DLQ tests should have a stable `DLQ consumer trace` name so they can be selected:

```bash
# PGMQ repository root, after implementing M3.1V and starting its test database.
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='--match "DLQ consumer trace"' --test-show-details=direct
```

Do not run or report the last selector as proof until tests with that name exist.
Use the existing `ChaosSpec` database fixtures and supported ephemeral-database
workflow; do not reset a user's unrelated database. For F8 core lifecycle regression:

```bash
# Shibuya repository root.
cabal test shibuya-core-test --test-show-details=direct
```


## Validation and Acceptance


Current implementation evidence is scoped: the core suite drives a mock adapter
through `runWithMetrics` and asserts exactly one span and the attribute union.
Kafka conversion tests assert the actual broker record's attributes but are not
an end-to-end `runApp` parent-link test. The recorded 2026-05-05 Jaeger smoke is
historical corroboration. F3 unit tests prove header merging; they do not prove
which span is active at the database write. M3.1V supplies that missing proof.

F8 is complete only when source and shutdown errors emit the specified spans
without changing failure/cancellation behavior or creating a new span per message.
F6 needs evidence addressing runner-level provider construction and the concrete
`getTracer` contract. F7 needs an explicit supported disabled callback contract,
with tests and docs reflecting whichever resolution is selected.

The documentation consolidation itself is accepted when there is one ID-9 file,
all eight findings and original implementation commits are retained, source status
matches current code, every newly written code fence has a language tag, local
links resolve, and inbound references to the removed companion are updated.
No model authorship is inferred for pre-provenance work; this review/update records
only its own verified runtime identity.


## Idempotence and Recovery


Re-reading the source and rerunning focused tests is safe; these commands do not
require publishing packages or changing committed pins. Preserve developer-local
configuration. If native libraries are missing, use the relevant development shell
and report setup failure separately from a failed behavioral assertion.

The deleted findings document and original long-form plan remain recoverable from
Git at the reviewed baseline. Restore only the needed historical text, rather than
reintroducing a second ID-9 plan. Keep current branch and unrelated edits intact.
For later implementation, make reversible per-repository commits with Conventional
Commit subjects. Local commits reference this repository-relative ExecPlan path;
adapter commits use `ExecPlan: mori://shinzui/shibuya/plans/9-audit-and-improve-opentelemetry-api`
and the active `Intention: intention_01kh0akd82ekat0be54p2f72kv` trailer where this
plan governs their work.


## Interfaces and Dependencies


The implemented interfaces are:

```haskell
-- shibuya-core/src/Shibuya/Core/Types.hs (field on Envelope)
attributes :: !(HashMap Text Attribute)

-- shibuya-core/src/Shibuya/Telemetry/Propagation.hs
extractTraceContext :: TraceHeaders -> Maybe SpanContext
injectTraceContext :: Span -> IO TraceHeaders
currentTraceHeaders :: (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)

-- shibuya-core/src/Shibuya/Telemetry/Effect.hs
runTracing :: (IOE :> es) => Tracer -> Eff (Tracing : es) a -> Eff es a
runTracingNoop :: (IOE :> es) => Eff (Tracing : es) a -> Eff es a
getTracer :: (Tracing :> es) => Eff es Tracer
withSpan' :: (Tracing :> es, IOE :> es) => Text -> SpanArguments -> (Span -> Eff es a) -> Eff es a

-- shibuya-core/src/Shibuya/App.hs
runApp :: (IOE :> es, Tracing :> es) => AppConfig -> [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
```

These are excerpts, not a complete standalone module. In particular, the first
line is a strict record-field declaration. `TraceHeaders` is a list of byte-string
key/value pairs. No `TracingConfig`, `runAppTraced`, or `Maybe Span` callback is
present. `Envelope.attributes` is not optional.

The checked-in core Cabal file currently uses `hs-opentelemetry-api ^>=1.0`,
`hs-opentelemetry-propagator-w3c ^>=1.0`, semantic conventions `^>=1.40`, and the
in-memory exporter `^>=1.0` for tests. Core does not currently depend on the SDK
initializer. Both adapter library stanzas target core `^>=0.10.0.0`. These describe
the working tree; no new bounds or pins are chosen by this review.

Upstream ownership is `mori://iand675/hs-opentelemetry`; curated lifecycle guidance
is `mori://iand675/hs-opentelemetry/docs/tracer-provider-guide`. Use Mori to locate
its source before changing APIs, and verify package-registry releases and upstream
tags before choosing any future compatibility bounds. The public getter is
`Shibuya.Telemetry.Effect.getTracer`; do not confuse it with an upstream function
of the same name when designing F6.

Kafka DLQ creation remains a separate missing feature: in
`mori://shinzui/shibuya-kafka-adapter`,
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs:329` warns that a
dead-lettered message is dropped because no DLQ producer exists, then follows its
offset path. PGMQ's F3 propagation fix does not implement Kafka DLQ delivery.


## Revision history


2026-05-05: Initial audit and implementation sequence, with intention
`intention_01kh0akd82ekat0be54p2f72kv`. Findings, core/adapter migrations, propagation
helper, and historical acceptance were recorded during that work.

2026-10-12: Reviewed current source and targeted tests; merged the companion audit
into this plan at the user's request. Preserved F1–F8 and implementation history,
replaced stale paths/signatures and contradictory statuses, recognized plan 25's
F4 resolution and plan 26's partial F7 improvement, separated missing tests from
missing features, and retained open work without claiming new implementation.
