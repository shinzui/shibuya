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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T23:38:40Z
      mode: "implement"
      note: "Implement remaining DLQ identity, lifecycle tracing, disabled API contract, and provider lifetime documentation."
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

The 2026-10-12 implementation closes the remaining audit work: enabled PostgreSQL
DLQ identity tests, source-lifetime and shutdown spans, a shared no-op tracer,
and an explicit compatible disabled-span contract with safe propagation. F4's dead
configuration was removed by plan 25; caller-managed provider ownership is retained.
The current guide includes a compiled and executed full-lifetime example. No
managed-provider helper or Kafka DLQ feature is added by this audit.


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
- [x] (2026-10-12T23:46Z) M3.1V — Four enabled-tracing PostgreSQL DLQ identity cases pass (direct/topic, original/no headers); producer and custom headers verified. Existing disabled test retained. Core active-header test compares exported IDs.
- [x] (2026-10-12T23:49Z) F6 — Shared private no-op tracer/provider preserves `getTracer :: Eff es Tracer`; independent-run stable-name and non-recording checks pass. No startup timing claim.
- [x] (2026-10-12T23:49Z) F7 — Accepted the compatible invalid, non-recording sentinel contract; Haddocks and tests specify zero IDs. Injection omits invalid contexts; enabled identity remains verified.
- [x] (2026-10-12T23:49Z) F8 implementation — Eight lifecycle exporter cases pass for finite single/batch sources, source failure, once-only shutdown, exception caching, timeout, cancellation, startup tracer capture, and disabled mode.
- [x] (2026-10-12T23:52Z) F8 regression validation — Core suite: 271 examples, 0 failures; `cabal build all`, `nix fmt`, and native-system `nix flake check` pass.
- [x] (2026-10-12T23:52Z) Documentation follow-up — Guide example compiled and ran successfully with SDK 1.0; provider timeout and finally-based app cleanup are explicit. ADR 12 distills ownership and disabled-context decisions.
- [x] (2026-10-12T23:55Z) Final integration check — PGMQ local-core suite: 181 examples, 0 failures; four DLQ identity cases pass with current runtime. Temporary gitignored override removed.


## Surprises & Discoveries


Implementation on 2026-10-12 used the existing ephemeral PostgreSQL fixture without
new infrastructure. Hackage preferred-version endpoints and upstream tags both
confirmed API and in-memory exporter 1.0.0.0 before adding adapter test bounds
`^>=1.0`. The exporter test generator is `DefaultIdGenerator`, as verified in
Mori-located source. The four DLQ cases passed in 5.2828 seconds. Core telemetry
passed 28 examples before disabled-contract changes. Lifecycle spans make total
span count exceed one; the ownership regression now asserts exactly one Consumer
span, retaining its attributes and override checks.


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

### Review discoveries on 2026-10-12 (before implementation)


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


Implementation on 2026-10-12 preserves `getTracer` and `withSpan'` signatures.
One private `NOINLINE` no-op tracer is initialized once with `unsafePerformIO`,
using only the public SDK constructor, no processors, and no background resource.
It never consults or replaces the global provider. The disabled callback sentinel
is accepted as an explicit compatibility contract, and invalid context injection
returns no headers. `currentTraceHeaders` also rejects invalid active contexts.
These are compatible API changes apart from intentionally correcting invalid
outgoing headers; there are no new library dependencies or bounds in core.

`AppHandle` captures the enabled startup tracer as `Maybe Tracer` so the public
`stopApp`/`stopAppGracefully` functions retain their IOE-only constraint. The
once-only leader wraps each adapter call in an Internal span and reuses existing
exception caching/deadlines. Both metrics ingester call sites wrap the entire
stream, not individual admissions, with one Internal span. Existing SDK span
bracketing records and rethrows synchronous/asynchronous errors. No tracing
provider is managed or shut down by Shibuya. The lifecycle ownership decision is
distilled in ADR 12; ADR 3 remains the failure/cancellation contract.


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


### Implementation acceptance on 2026-10-12


Core build and full tests passed: 271 examples, 0 failures, including 39 telemetry
examples and existing lifecycle regressions. Metrics integration passed 104
examples, 0 failures. Both modified repositories passed `cabal build all`, `nix fmt`,
and native `nix flake check` (treefmt and pre-commit). The PGMQ suite passed 181
examples against published core, including four new enabled-tracing identity cases;
its test commit is `341c2a9` in `mori://shinzui/shibuya-pgmq-adapter` (commit artifact
URI pending). Local-core validation initially found two older test fixtures building
`AppConfig` without the new strict `metricsDetail` field. They now update
`defaultAppConfig` instead, compatible with both the published and current core.
The final local-core full suite passed 181 examples in 64.7292 seconds using a
temporary gitignored override, now removed. Cabal plan metadata confirms the local
core package source. Both published and current-core DLQ identity cases pass.

The exact guide Quick Start was extracted to `/tmp/plan9-quickstart.hs`, compiled
via `cabal exec -- ghc -XGHC2024 -threaded /tmp/plan9-quickstart.hs -o /tmp/plan9-quickstart`,
and executed as `OTEL_TRACES_EXPORTER=none /tmp/plan9-quickstart` with exit 0. This
proves the example's current SDK types and cleanup execute; exporter behavior is
covered by the separate in-memory lifecycle tests, not claimed from that smoke.
No benchmark, new Jaeger/Redpanda smoke, dependency release, or performance timing
claim was added. The flake checks cover the native system, not every platform.

### Verified implementation state


The audit's span-ownership fixes remain: core `7c6586b` supplies attributes, Kafka
conversion supplies system/partition/offset, and PGMQ supplies an empty map. Core
`193de1d` and the PGMQ migration provide outgoing consumer context. The strengthened
ownership regression verifies exactly one Consumer span and adapter override
precedence alongside the new ingestion span. F3 now has actual PostgreSQL span-ID
and trace-ID equality proof. F4's config removal in `a96ad52` remains the resolution.
F6 shares a private no-op provider while preserving the concrete getter. F7 accepts
and documents the compatible zero-ID sentinel, with invalid-context propagation
suppressed. F8 provides ingestion-lifetime and adapter-shutdown spans with tested
error, cancellation, timeout, and once-only behavior.

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
was claimed by the preceding documentation-only review. Subsequent implementation
acceptance is recorded above, including the PostgreSQL identity tests.


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
which upgrades the SDK-facing code. The original review found no dedicated OTel ADR; implementation adds
[ADR 12](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md)
for span ownership, provider lifetime, and the disabled-context contract. [ADR 3](../adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md)
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
requires exactly one exported Consumer span, alongside one ingestion-lifetime span.

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


### Finding F3 — DLQ forwards the original parent (D, original P1): implemented and verified


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
no-op fallback against the database. Four enabled-tracing “DLQ consumer trace” cases
now compare both IDs with the exported process span, for direct/topic routes and
original/no headers; they verify stashed upstream values and custom fields. Adapter
commit `341c2a9` adds this proof (commit artifact URI pending).


### Finding F4 — Dead config and provider lifecycle (A, original P1): dead config resolved; helper not implemented


Plan 25 deliberately removed `TracingConfig` rather than wiring it into an exporter
configuration path already served by `OTEL_*` and the choice of runner. Source
`shibuya-core/src/Shibuya/App.hs:209` still requires `Tracing :> es`; callers own the
provider lifetime. There is no `runAppTraced` or `withTracing` helper. The original
helper proposal is superseded as a required fix, and its handle-returning bracket
would have been too short-lived.

An optional future helper must keep the provider alive through processor completion
and shutdown, and test success, startup failure, exception, and cancellation. The
Quick Start in `docs/user/opentelemetry.md` now uses `Just 5_000_000` for provider
shutdown and an effectful `finally` around `waitApp`/`stopApp`. Its complete finite
source example was compiled with SDK 1.0 and executed successfully. This corrects
the documentation without introducing another configuration or provider helper.


### Finding F5 — No convenient active-context injection (D, original P2): implemented


`shibuya-core/src/Shibuya/Telemetry/Propagation.hs:77` exposes
`currentTraceHeaders :: (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`.
It returns `Nothing` with tracing disabled or no active span, otherwise calls the
retained `injectTraceContext`. PGMQ consumes it in the actual DLQ path, so the
original claim that adapters never exercise injection is obsolete. Haddocks explain
both APIs. `PropagationSpec` now compares exported IDs and covers disabled, absent,
and invalid active contexts. `injectTraceContext` uses the SDK's public `isValid`
check before encoding; valid non-recording contexts remain propagatable.


### Finding F6 — No-op provider allocation (A, P2): implemented


`shibuya-core/src/Shibuya/Telemetry/Effect.hs` now evaluates a shared private
`noopTracer` instead of constructing a provider in each `runTracingNoop` call.
A `NOINLINE` top-level constant initializes the no-processor provider once through
`unsafePerformIO`. The public SDK has no pure concrete tracer constructor, so this
retains the public `getTracer :: Eff es Tracer` contract without depending on
SDK internals or the mutable global provider. No exporter/background resource is
allocated. `EffectSpec` compares stable provider identity across independent runs,
uses the returned tracer directly, and checks non-recording behavior. Existing
no-op action-result tests pass. This removes repeated construction; no measured
startup-cost or throughput improvement is claimed.


### Finding F7 — Disabled callback exposes zero IDs (A, P2): explicit compatible contract accepted


The `withSpan'` callback retains `Span -> Eff es a`. Disabled mode supplies the
existing shared non-recording sentinel, whose zero trace/span IDs explicitly
represent absence. Haddocks and the guide forbid correlation or parenting with
those invalid IDs. `EffectSpec` inspects both IDs, checks non-recording behavior,
and proves `injectTraceContext` returns an empty list. `currentTraceHeaders`
returns `Nothing` under disabled mode or an invalid active context. Enabled
identity tests continue to compare real exported IDs. The optional `Maybe Span`
proposal is deliberately not implemented; preserving callers' signatures is the
chosen resolution, not an accidental deferral.


### Finding F8 — No framework ingestion/shutdown spans (B, P2): implemented


`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs` wraps the metrics ingester's
entire stream in the Internal `shibuya.ingest` span and adds `shibuya.processor.id`.
Both single and batch call sites in `Shibuya.Internal.Runner.Supervised` pass the
processor identity. No additional per-message ingestion span is introduced.
`shibuya-core/src/Shibuya/App.hs` wraps each adapter shutdown attempt in an Internal
`<ProcessorId> shutdown` span, using the optional tracer captured at startup in
`shibuya-core/src/Shibuya/Internal/App.hs`. Stop APIs retain their IOE-only constraint.

SDK brackets record exception events and Error status before rethrowing failures,
including cancellation and deadlines. The existing leadership, cached result,
total deadline, synchronous-failure continuation, and unconditional master cleanup
remain in place. `LifecycleSpec` verifies finite single/batch streams, source
failure and its terminal lifecycle, normal and repeated shutdown, cached thrown
failure, deadline False result, cancellation of ingestion, tracer capture across
runners, and no spans in disabled mode. All eight exporter cases and the full core
suite pass. Long-lived spans normally export on end; live visibility of unfinished
operations still comes from lifecycle metrics.


### Milestones and execution results


M1 (audit) and M2 (F1/F2 plus both adapter migrations) were already complete.
M2 acceptance remains one exported Consumer process span with the union of
framework/adapter attributes. The test now distinguishes that span from lifecycle
Internal spans and retains its override assertions.

M3.1V adds four enabled PostgreSQL cases in the PGMQ `ChaosSpec`, using its existing
ephemeral database fixture and an in-memory exporter around a real `runApp` handler.
The app is stopped while the provider remains alive, so finalization finishes
before the DLQ row and exported spans are inspected. Both trace and span IDs must
match the failing Consumer span. Original producer headers are stashed, custom
headers survive, and messages without original headers acquire valid consumer
context. The original disabled test remains. Test-only API/exporter bounds are
`^>=1.0`, verified against Hackage and upstream tags. The four cases and the full
181-example adapter suite passed against published core; local-core verification
is recorded in Progress and final outcomes. Core `PropagationSpec` also checks
exact active/exported ID equality.

M3.2 implements F8's ingestion and shutdown coverage. Eight exporter tests run via
`--match Shibuya.Telemetry.Lifecycle`; they check kind, processor identity, error
events/status, once-only calls, cached failures, timeout results, cancellation,
startup tracer capture, and disabled mode. Full core lifecycle regressions run
through `cabal test shibuya-core-test`: 271 examples passed.

M3.3 resolves F6/F7 without breaking callback/getter signatures. The shared private
no-op provider is verified across independent invocations, and the sentinel's
non-recording/invalid-ID contract is tested. Injection rejects invalid contexts
while valid active-span behavior remains. ADR 12 records these durable choices.

M4 corrects and validates the current guide. Its finite-source example keeps the
provider alive through waiting and unconditional stop cleanup and supplies the
required shutdown timeout. The example compiles and executes. No deleted legacy
plan, managed provider helper, Kafka DLQ producer, release publication, or new
benchmark requirement is part of this implementation.


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

The four tests with that selector now exist and pass. Use the existing `ChaosSpec` database fixtures and supported ephemeral-database
workflow; do not reset a user's unrelated database. For local integration validation, resolve the core package with
`mori path mori://shinzui/shibuya/packages/shibuya-core`. Add its absolute path as
an extra `packages:` entry in the PGMQ checkout's gitignored `cabal.project.local`,
preserving any existing local settings. Run the full PGMQ suite with the same
command above but no `--match` filter. The recorded implementation used the sibling
checkout of that canonical core project; Cabal's plan JSON reported it as a local
package. Remove only the temporary entry/file you introduced after validation;
no override is committed. Both published-core and local-core full runs passed.

For F8 core lifecycle regression:

```bash
# Shibuya repository root.
cabal test shibuya-core-test --test-show-details=direct
```


## Validation and Acceptance


Current implementation evidence is scoped: the core suite drives a mock adapter
through `runWithMetrics` and asserts exactly one Consumer span and the attribute
union, alongside the ingestion-lifetime Internal span.
Kafka conversion tests assert the actual broker record's attributes but are not
an end-to-end `runApp` parent-link test. The recorded 2026-05-05 Jaeger smoke is
historical corroboration. F3 unit tests prove header merging; the new M3.1V PostgreSQL cases supply actual
consumer-to-DLQ span identity proof.

F8 acceptance is demonstrated by eight lifecycle exporter cases and the full core
regression suite: source/shutdown errors retain events and status without changing
failure, timeout, or cancellation results. F6's independent-run provider identity
and direct tracer use prove shared construction plus compatibility. F7's explicit
sentinel contract, invalid injection tests, and enabled identity test cover both
modes. The guide's exact code block compiles and executes with the current SDK.

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

2026-10-12 implementation: Closed M3.1V with PostgreSQL span-identity tests and
strengthened the core assertion; lifecycle and disabled-contract work is underway.

2026-10-12 implementation: Lifecycle exporter and disabled-contract cases pass
(38 telemetry examples total); full regression gates and guide validation remain.

2026-10-12 implementation: Reconciled all finding statuses and milestone
instructions with implemented behavior, recorded core and published-core adapter
full-suite results, and distilled ADR 12. Final local-core adapter check passed all 181 examples.

2026-10-12 implementation: Corrected two PGMQ fixture constructions discovered
when compiling against current core; they use default config record updates and
retain behavior. Recorded the 104-example metrics integration regression pass.

2026-10-12 completion: All audit findings are implemented or explicitly resolved,
all remaining progress items are checked, and the guide/ADR and multi-repository
validation evidence are current. No benchmark or release publication is claimed.
