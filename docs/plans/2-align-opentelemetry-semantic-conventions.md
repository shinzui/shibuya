# Align Shibuya's OpenTelemetry attribute keys with the official semantic conventions

Intention: intention_01kpgjfhrfe499b5vtpa043pyx

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

Shibuya is a Haskell queue-processing framework (see `CLAUDE.md`) that emits
OpenTelemetry (OTel) spans for every message it processes. Today the attribute
keys used on those spans are hand-written `Text` constants in
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` (`"messaging.message.id"`,
`"messaging.destination.partition.id"`, `"shibuya.ack.decision"`, …). Some match
the upstream OTel semantic-conventions spec, some do not, and one
(`messaging.destination.partition.id`) is not a key defined anywhere in v1.24 of
the spec.

After this change, a user who runs the `shibuya-pgmq-example` consumer with
`OTEL_TRACING_ENABLED=true` and watches the Jaeger UI at
`http://127.0.0.1:16686` will see spans whose attribute keys match the exact
dotted names documented in the upstream OpenTelemetry semantic-conventions
specification. Every "messaging" attribute will use the typed `AttributeKey`
values exported by `OpenTelemetry.SemanticConventions` (from the
`hs-opentelemetry-semantic-conventions` library), so if the library is upgraded
and a key is renamed upstream, the Haskell compiler will flag the mismatch
instead of silently emitting a stale string.

Concretely, after this work:

-   Every messaging-related attribute on a processing span (`messaging.system`,
    `messaging.message.id`, `messaging.destination.name`, `messaging.operation`)
    is taken from `OpenTelemetry.SemanticConventions`, not from a hand-written
    string.
-   The span emitted per message is named following the
    OTel messaging-spans spec's recommended pattern
    `<destination> <operation>` — i.e. `"<processor-id> process"` (e.g.
    `"shibuya-consumer process"`) — instead of the hard-coded
    `"shibuya.process.message"`. (Note: the in-tree
    `hs-opentelemetry-instrumentation-hw-kafka-client` uses
    `"process <topic>"` order; see Decision Log for why we follow the
    spec's order rather than that example's.)
-   `messaging.operation` is set to `"process"` on the consumer span, which
    today is absent. Because Shibuya's `processOne` span wraps the
    user handler (not just message receipt), this label is accurate
    for the span's actual duration.
-   The never-defined `messaging.destination.partition.id` key is removed; when
    an adapter actually reports a partition, Shibuya emits it under the
    vendor-specific key the spec defines (today we keep a shibuya-namespaced
    fallback, see Decision Log).
-   Handler-level events (`handler.started`, `handler.completed`,
    `handler.exception`) remain under the `shibuya.*` namespace but are renamed
    so that the domain prefix is clear (`shibuya.handler.started`, etc.) and so
    that they cannot be confused with future upstream names.
-   Shibuya's own domain attributes (`shibuya.processor.id`,
    `shibuya.inflight.count`, `shibuya.inflight.max`, `shibuya.ack.decision`)
    remain in the `shibuya.*` namespace — these are legitimately not upstream
    — and are documented as such in `Shibuya/Telemetry/Semantic.hs`.

Observable outcomes:

1.  Running the existing test suite (`cabal test shibuya-core-test`) produces
    the same pass count as before the change, with one new spec file for the
    attribute-key alignment.
2.  Running the example (see "Validation and Acceptance") and filtering traces
    in Jaeger on attribute `messaging.operation=process` returns the consumer
    spans — today the same filter returns zero results because the attribute is
    never set.
3.  A grep `rg 'AttributeKey "' shibuya-core/src/` returns zero lines outside
    of `Shibuya.Telemetry.Semantic`, proving that only one module constructs
    attribute-key names and everything else imports from there or from the
    upstream semantic-conventions package.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into
two ("done" vs. "remaining"). This section must always reflect the actual
current state of the work.

-   [x] M1.1 — Add `hs-opentelemetry-semantic-conventions` to
    `shibuya-core/shibuya-core.cabal`'s `build-depends`, and verify it resolves
    under the current nix devShell (`cabal build shibuya-core` succeeds).
    Done 2026-04-21. Required also adding a matching
    `source-repository-package` stanza in `cabal.project` (subdir
    `semantic-conventions`, same git tag as the other hs-opentelemetry
    deps) — the package is not on Hackage at this commit and the project
    pulls the others from git already.
-   [x] M1.2 — In `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`, rewrite the
    existing `Text` attribute constants so they are derived from the typed
    `AttributeKey` exports of `OpenTelemetry.SemanticConventions` where those
    exports exist (`messaging_system`, `messaging_message_id`,
    `messaging_destination_name`, `messaging_operation`). Done 2026-04-21.
    `unkey` is re-exported from `OpenTelemetry.Attributes` (via
    `AttributeKey(..)`), so a single import covers both.
-   [x] M1.3 — Keep `shibuya.*` keys (`shibuya.processor.id`,
    `shibuya.inflight.count`, `shibuya.inflight.max`, `shibuya.ack.decision`)
    as hand-written `Text` but document next to each one that it is
    intentionally outside the upstream spec, and rename the handler event names
    to the `shibuya.handler.*` namespace. Done 2026-04-21.
-   [x] M1.4 — Delete `attrMessagingDestinationPartitionId` (which corresponds
    to no upstream key in v1.24) and replace its single call site in
    `Shibuya/Runner/Supervised.hs` with a shibuya-namespaced `shibuya.partition`
    key, recording the decision in the Decision Log. Done 2026-04-21.
    Also dropped the redundant `eventHandlerException` event — the
    preceding `recordException` call already emits the standard
    `exception` event the spec defines.
-   [x] M2.1 — Update `Shibuya/Runner/Supervised.hs::processOne` so that: (a)
    the span name is produced by a helper `processSpanName ::
    ProcessorId -> Text` returning `"<pid> process"`, and (b)
    `messaging.operation` is set to `"process"` and `messaging.destination.name`
    is set to the processor id on every span. Done 2026-04-21. (The
    helper takes `Text`, not `ProcessorId`, since `processOne` already
    has the unwrapped `pidText` in scope.)
-   [x] M2.2 — Thread the `ProcessorId` into `processOne` (today it is only
    available in the caller `runWithMetrics`/`runSupervised`). Confirm by
    reading the span name in an in-memory exporter test. Done 2026-04-21
    for the threading; confirmation via in-memory exporter test deferred
    to M3.1.
-   [x] M3.1 — Add a new HSpec file
    `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` that records a span
    end-to-end through `processOne` against an in-memory OTLP exporter and
    asserts the final attribute names and span name. Done 2026-04-21.
    Drives `processOne` indirectly via the existing public
    `runWithMetrics` entrypoint (with a one-message `listAdapter`),
    rather than by exporting `processOne` itself — keeps the public
    surface unchanged. Required adding
    `hs-opentelemetry-exporter-in-memory` as a sibling
    `source-repository-package` (same git tag, `subdir:
    exporters/in-memory`) and to the test stanza's `build-depends`
    along with `unordered-containers` and `vector` (used directly by
    the spec, previously transitively-pulled).
-   [x] M3.2 — Update `docs/plans/OPENTELEMETRY_INTEGRATION.md` to note that
    attribute keys are now imported from `OpenTelemetry.SemanticConventions`
    and to reference this plan. Done 2026-04-21.
-   [x] M3.3 — Run `nix fmt` and `nix flake check`; run
    `cabal test shibuya-core-test`; verify the example against Jaeger.
    Done 2026-04-21 for the local gates: `nix fmt`,
    `nix flake check`, `cabal build all`, and
    `cabal test shibuya-core-test` (92 examples, 0 failures — the
    SemanticSpec is the new 92nd example) all clean. The Jaeger
    end-to-end check (`Validation and Acceptance` section, steps 1–4)
    is the only remaining manual verification — left to the user
    because it requires running PostgreSQL, Jaeger, and the pgmq
    consumer/simulator outside the test sandbox.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered
during implementation. Provide concise evidence.

-   2026-04-21: A close re-read of
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-hw-kafka-client-Instrumentation-Guide.md`
    corrected two assumptions in the initial draft of this plan:
    -   The hw-kafka-client consumer helper sets
        `messaging.operation="process"` (not `"receive"` as the original
        Decision Log claimed). See the guide's "Recorded Attributes"
        section, line `messaging.operation — "send" for producers,
        "process" for consumers.` This makes our choice of `"process"`
        more directly aligned with the worked example, not less.
    -   hw-kafka-client names its consumer span `"process <topic-name>"`
        (operation first). The OTel messaging-spans spec recommends
        `"<destination> <operation>"` (destination first). The two
        diverge. We follow the spec; see the new Decision Log entry on
        span-name order.
-   2026-04-21: hw-kafka-client's guide flags that its consumer span
    "closes around a no-op" — i.e. the span only covers `pollMessage`
    itself, not the user's processing logic. Shibuya's `processOne`
    span wraps the handler call and the ack finalize, so our consumer
    span genuinely represents the duration of a process operation, not
    just a receive. This is a property worth preserving and it makes
    the `"process"` label more accurate for Shibuya than for the
    Kafka instrumentation that inspired it.
-   2026-04-21: `hs-opentelemetry-semantic-conventions` is not on
    Hackage at the version pin used by the rest of the in-tree
    `iand675/hs-opentelemetry` packages, so the cabal `build-depends`
    addition alone wasn't enough — `cabal build` failed with
    `unknown package: hs-opentelemetry-semantic-conventions`. The fix
    was to add a sibling `source-repository-package` block in
    `cabal.project` mirroring the existing `subdir: api` /
    `subdir: sdk` / `subdir: propagators/w3c` entries (same git url,
    same tag `adc464b…`, `subdir: semantic-conventions`). Cabal then
    cloned the repo, fetched the conventions submodule, and built the
    package successfully.


## Decision Log

Record every decision made while working on the plan.

-   Decision: Use `hs-opentelemetry-semantic-conventions` (the existing Haskell
    code-generated library from the upstream OTel conventions YAML) rather
    than copying attribute strings into shibuya by hand.
    Rationale: The semantic-conventions guide at
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-Semantic-Conventions-Guide.md`
    explicitly documents this pattern. Using it means future upstream renames
    (the guide specifically mentions `net.*` → `network.*`) will break
    compilation, which is the intended signal. It is also what the
    `hs-opentelemetry-instrumentation-hw-kafka-client` package does, giving us
    a worked example in-tree.
    Date: 2026-04-21.

-   Decision: Remove the key `messaging.destination.partition.id` and replace
    it with the shibuya-namespaced `shibuya.partition` wherever Shibuya today
    has only a partition string but no specific broker context.
    Rationale: In semantic-conventions v1.24 there is no generic
    `messaging.destination.partition.id`. The nearest keys are
    `messaging.eventhubs.destination.partition.id` (Text, EventHubs-only) and
    `messaging.kafka.destination.partition` (Int64, Kafka-only). Until
    Shibuya has Kafka- or EventHubs-specific adapters that know which broker
    is in use, emitting a broker-specific key would be a lie. A
    shibuya-namespaced attribute is honest, does not collide with any upstream
    key, and can be migrated later when an adapter gains the context to use
    the right system-specific key.
    Date: 2026-04-21.

-   Decision: Keep `shibuya.processor.id`, `shibuya.inflight.count`,
    `shibuya.inflight.max`, and `shibuya.ack.decision` in the `shibuya.*`
    namespace rather than trying to map them onto upstream concepts.
    Rationale: The inflight count and ack decision are specific to Shibuya's
    supervision and ack-handle model; there is no upstream key for them.
    `shibuya.processor.id` is a deployment-level identifier of a specific
    Shibuya processor, which is not an upstream notion either. The
    semantic-conventions guide is explicit that attributes outside the spec
    should use a vendor-prefixed name, which `shibuya.*` satisfies.
    Date: 2026-04-21.

-   Decision: Rename the hand-crafted events `handler.started`,
    `handler.completed`, `handler.exception`, `ack.decision` to
    `shibuya.handler.started`, `shibuya.handler.completed`,
    `shibuya.handler.exception`, `shibuya.ack.decision` respectively, so that
    they cannot clash with any future upstream event name, and drop the
    standalone `shibuya.handler.exception` event in favor of
    `OTel.recordException` which already records the canonical `exception`
    event the spec defines.
    Rationale: The upstream spec does not define `handler.*` events, but it
    does define a standard `exception` event (see
    `semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`
    `exception_type`, `exception_message`, `exception_stacktrace`,
    `exception_escaped`). The existing `recordException` call in
    `processOne` already emits the standard event; the redundant custom
    `handler.exception` event is noise.
    Date: 2026-04-21.

-   Decision: Set `messaging.operation` to the literal string `"process"`.
    Rationale: The upstream messaging conventions define a small enum —
    `publish`, `receive`, `process`, `settle`, `create`. Shibuya's
    `processOne` runs the user handler against a message that has already
    been received from the queue's stream source, so `"process"` is the
    correct value. The worked example
    `hs-opentelemetry-instrumentation-hw-kafka-client` also tags its
    consumer span with `messaging.operation="process"` (see
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-hw-kafka-client-Instrumentation-Guide.md`,
    "Recorded Attributes"). One difference worth noting: that
    instrumentation's consumer span only wraps the `pollMessage` call —
    its own guide flags this as a caveat ("Consumer spans close around a
    no-op"). Shibuya's per-message span wraps the user handler too, so
    the `"process"` label is unambiguously accurate for us — the span's
    duration genuinely represents processing time, not just receive time.
    Date: 2026-04-21.

-   Decision: Bundle Milestone 1 and Milestone 2 into a single git
    commit rather than splitting into two as the original Concrete
    Steps prescribed.
    Rationale: Both milestones edit the same two files
    (`Shibuya/Telemetry/Semantic.hs` and `Shibuya/Runner/Supervised.hs`)
    in interleaved hunks — for example, M1 renames the event constants
    in Semantic.hs while M2 replaces `processMessageSpanName` with
    `processSpanName` in the same export list. Splitting the work
    after the fact via `git add -p` would have produced a fragile
    intermediate state with a half-renamed module, defeating the
    bisectability the split was supposed to provide. The combined
    commit still leaves the codebase in a working state with full
    test coverage on either side. M3 (the new test + docs) remains a
    separate commit as planned.
    Date: 2026-04-21.

-   Decision: Use the OTel-spec-recommended span-name order
    `"<destination> <operation>"` (e.g. `"shibuya-consumer process"`)
    rather than the operation-first order
    (`"process <destination>"`) that
    `hs-opentelemetry-instrumentation-hw-kafka-client` uses for its
    consumer span (`"process <topic-name>"`).
    Rationale: The OTel messaging-spans specification recommends
    `<destination name> <operation name>` as the span name. We follow
    the spec rather than the in-tree Kafka instrumentation's word order
    because (a) the spec is the contract Jaeger/other backends optimize
    against and (b) this format keeps the destination at the front,
    which is more useful for filtering and grouping in trace UIs. The
    departure from hw-kafka's order is intentional and small (the
    attribute set is identical), and is documented here so a reader
    comparing the two does not assume one of them is buggy.
    Date: 2026-04-21.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at
completion. Compare the result against the original purpose.

-   2026-04-21, end of implementation (M1+M2+M3 complete; only the
    manual Jaeger smoke-check remains):

    -   The original purpose is met. Every messaging-related attribute
        on a Shibuya processing span is now derived from the typed
        `AttributeKey` exports of `OpenTelemetry.SemanticConventions`,
        the per-message span name follows the spec's
        `<destination> <operation>` pattern,
        `messaging.operation=process` is always set, the never-defined
        `messaging.destination.partition.id` is gone (replaced by
        `shibuya.partition`), handler events are namespaced
        `shibuya.handler.*`, and the redundant custom
        `handler.exception` event is gone in favor of the standard
        `exception` event emitted by `recordException`.
    -   Test coverage: `shibuya-core-test` went from 91 to 92 passing
        examples; the new `Shibuya.Telemetry.Semantic (wire-format)`
        spec drives `processOne` end-to-end through `runWithMetrics`
        against an in-memory span exporter and asserts the wire
        names of every attribute and the two `shibuya.handler.*`
        events. A future upstream rename will break both compilation
        (in `Shibuya/Telemetry/Semantic.hs`) and this test.
    -   Build hygiene: clean across `cabal build all` and
        `nix flake check`. The two new
        `source-repository-package` entries
        (`semantic-conventions` and `exporters/in-memory`) reuse
        the existing tag pin so we don't introduce a new git
        revision to track.

    -   Gaps:
        -   The end-to-end Jaeger validation
            (`Validation and Acceptance` section, steps 1–4) was not
            executed in this session — it requires PostgreSQL, Jaeger,
            and the pgmq consumer/simulator running locally. The
            in-memory exporter test covers the same wire-name
            guarantees, but the visual confirmation in the Jaeger UI
            is still a useful smoke-check before declaring the
            initiative done.
        -   `attrShibuyaProcessorId` is exported but currently has no
            call site (the processor id is now exposed via the
            spec-aligned `messaging.destination.name`). It is
            preserved for adapters/instrumentation that want to
            disambiguate processor identity from queue identity in
            future work.

    -   Lessons:
        -   Adding a single `build-depends` line wasn't enough — the
            in-tree `iand675/hs-opentelemetry` packages are pulled by
            git pin, so the corresponding
            `source-repository-package` block had to be added to
            `cabal.project` for both `semantic-conventions` and
            `exporters/in-memory`. Worth recording for the next
            person who reaches for one of these subpackages.
        -   The typed `AttributeKey` newtype is exported from
            `OpenTelemetry.Attributes` (via `AttributeKey(..)`); no
            need to dive into `OpenTelemetry.Attributes.Key` as the
            initial draft hedged.
        -   `OpenTelemetry.Internal.Trace.Types` is a hidden module;
            `ImmutableSpan(..)` and `Event(..)` are re-exported from
            `OpenTelemetry.Trace.Core`. A short detour but easy to
            miss when scaffolding a new test.


## Context and Orientation

Shibuya is a Haskell library for supervised queue processing. The top-level
layout, as documented in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/CLAUDE.md`,
is:

    shibuya-core/          # The library being changed.
      src/Shibuya/
        Core/              # Envelope, Ingested, AckHandle, Lease, Types.
        Runner/            # Master, Supervised, Processor, Ingester, Metrics, Halt.
        Adapter/           # Mock adapter; real adapters live in sibling packages.
        App.hs             # runApp entry point.
        Handler.hs
        Policy.hs
        Telemetry.hs       # Re-export façade for the Shibuya.Telemetry.* modules.
        Telemetry/
          Config.hs        # TracingConfig record.
          Effect.hs        # `Tracing :: Effect` + runners, `withSpan'`, helpers.
          Propagation.hs   # W3C TraceContext header ↔ SpanContext.
          Semantic.hs      # <-- ATTRIBUTE KEY CONSTANTS LIVE HERE.
      test/Shibuya/
        Telemetry/
          EffectSpec.hs
          PropagationSpec.hs

    shibuya-pgmq-example/  # Real-world consumer/simulator using PostgreSQL pgmq.
      src/Example/
        Config.hs
        Telemetry.hs       # withTracing bracket for the global TracerProvider.
      app/
        Consumer.hs
        Simulator.hs

    docs/plans/            # ExecPlans live here (this file is plan #2).

Key facts about the current code relevant to this change:

-   `shibuya-core/shibuya-core.cabal` currently depends on
    `hs-opentelemetry-api ^>=0.3` and `hs-opentelemetry-propagator-w3c ^>=0.1`,
    but **not** on `hs-opentelemetry-semantic-conventions`. Both packages
    live locally at
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`, which
    `mori registry show iand675/hs-opentelemetry` confirms.
-   The generated module
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`
    contains roughly 9,300 lines of typed `AttributeKey a` values. The ones
    this plan uses are:

        messaging_system              :: AttributeKey Text  -- "messaging.system"
        messaging_message_id          :: AttributeKey Text  -- "messaging.message.id"
        messaging_destination_name    :: AttributeKey Text  -- "messaging.destination.name"
        messaging_operation           :: AttributeKey Text  -- "messaging.operation"

-   `AttributeKey a` is defined in `hs-opentelemetry-api` as
    `newtype AttributeKey a = AttributeKey { unkey :: Text }`. The phantom
    type `a` is the Haskell type the value must have. The `unkey` field
    extracts the dotted wire-name as plain `Text`, which is what
    Shibuya's current helpers (`addAttribute :: Span -> Text -> a -> Eff es ()`)
    expect.
-   The call sites this plan touches:
    -   `shibuya-core/src/Shibuya/Telemetry/Semantic.hs` — defines every
        attribute-key and event-name constant Shibuya uses. All of the
        `attr*` and `event*` names.
    -   `shibuya-core/src/Shibuya/Runner/Supervised.hs` — the only consumer
        of those constants today. Lines 66–90 import them; lines 364–445
        use them inside the `processOne` function, which is the per-message
        span.
    -   `shibuya-core/src/Shibuya/Telemetry.hs` — re-exports `Semantic` so
        users can `import Shibuya.Telemetry`.
    -   `shibuya-core/src/Shibuya/Telemetry/Effect.hs` — unaffected by this
        plan except as a reference; its `addAttribute` takes a `Text` key
        which is satisfied by `unkey someAttributeKey`.
-   No test file under `shibuya-core/test/` or example under
    `shibuya-pgmq-example/` references `attrShibuya*`, `attrMessaging*`, or
    any of the event names directly. A plain `grep` shows zero hits outside
    `Semantic.hs` and `Supervised.hs`, so there is a single chokepoint to
    change.
-   The git status at plan-creation time is `M mori.dhall` plus no other
    uncommitted work related to telemetry.

Terms used in this plan:

-   **OTel / OpenTelemetry**: the vendor-neutral observability specification
    at `https://opentelemetry.io`. Shibuya uses its tracing half (spans).
-   **Semantic convention**: an upstream-defined dotted name and expected
    value type for a span/metric attribute. Example: the spec says that a
    consumer span should carry `messaging.operation` with value `"process"`
    when it represents processing a message; the *name* and *value type*
    are the "convention".
-   **AttributeKey**: a phantom-typed `newtype` over `Text` that carries
    the dotted convention name as its value and the expected Haskell type
    as its phantom. Importing `messaging_operation` from
    `OpenTelemetry.SemanticConventions` gives you the canonical spelling
    and the expectation that its value is `Text`.
-   **Span**: a single timed, named operation within a distributed trace.
    Shibuya creates one per message in `processOne`.
-   **Event on a span**: an instantaneous, named record attached to a span
    (for example, "handler started at t0"). Shibuya emits
    `handler.started`/`handler.completed`/`handler.exception` today.
-   **Processor**: a single Shibuya consumer of one queue, identified by
    a `ProcessorId` (a newtype over `Text`).


## Plan of Work

The work is three small, independently testable milestones. Keep each milestone
compiling, formatted (`nix fmt`), and tested (`cabal test shibuya-core-test`)
at its end.

### Milestone 1 — Wire up the typed attribute keys

Scope: add the dependency, rewrite `Shibuya.Telemetry.Semantic` so it is
driven by typed `AttributeKey`s where upstream keys exist, remove the
non-existent key, and keep everything compiling. At the end of this
milestone, nothing downstream has changed its behavior; the wire-format
attribute strings emitted on spans are identical to those emitted today
for every key that remains.

Work:

1.  In `shibuya-core/shibuya-core.cabal`, add the line

        , hs-opentelemetry-semantic-conventions

    to the library's `build-depends`, immediately under the existing
    `hs-opentelemetry-api ^>=0.3,` line. Do not pin a specific version: the
    local nix overlay supplies one, which will be the one resolved during
    `cabal build`. (If cabal complains about an unbounded dependency, add
    `^>=<major>.<minor>` matching whatever version `cabal build` reports.)
2.  In `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`:
    -   Import `OpenTelemetry.SemanticConventions` (qualified as `Sem` is
        a concise alias).
    -   Change the four messaging constants to be derived from the typed
        exports by taking their `unkey`:

            attrMessagingSystem :: Text
            attrMessagingSystem = OTel.unkey Sem.messaging_system

            attrMessagingMessageId :: Text
            attrMessagingMessageId = OTel.unkey Sem.messaging_message_id

            attrMessagingDestinationName :: Text
            attrMessagingDestinationName = OTel.unkey Sem.messaging_destination_name

            attrMessagingOperation :: Text
            attrMessagingOperation = OTel.unkey Sem.messaging_operation

        where `OTel.unkey` is exported from `OpenTelemetry.Attributes` in
        the API package (the `AttributeKey` newtype selector). If
        `unkey` is not re-exported by
        `OpenTelemetry.Attributes`, import it from
        `OpenTelemetry.Attributes.Key` (see
        `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Attributes/Key.hs`).
    -   Delete `attrMessagingDestinationPartitionId`. Add instead a
        shibuya-namespaced constant

            attrShibuyaPartition :: Text
            attrShibuyaPartition = "shibuya.partition"

        with a Haddock note explaining that no portable upstream key
        exists for an abstract partition identifier in v1.24; system-
        specific adapters may choose to emit `messaging.kafka.destination.partition`
        or `messaging.eventhubs.destination.partition.id` in addition.
    -   Rename the event constants:

            eventHandlerStarted   -> "shibuya.handler.started"
            eventHandlerCompleted -> "shibuya.handler.completed"
            eventAckDecision      -> "shibuya.ack.decision"

        and delete `eventHandlerException`: the spec's `exception` event,
        already emitted by `OTel.recordException` in `processOne`, covers
        this case. Keep the *variable names* the same
        (`eventHandlerStarted`, etc.) so the call sites only change
        strings, not identifiers.
    -   Export `attrMessagingOperation` and `attrShibuyaPartition` in the
        module header; remove `attrMessagingDestinationPartitionId` and
        `eventHandlerException` from the export list.
3.  In `shibuya-core/src/Shibuya/Runner/Supervised.hs`, update the import
    list (lines 76–90) to drop `attrMessagingDestinationPartitionId` and
    `eventHandlerException` and add `attrMessagingOperation` and
    `attrShibuyaPartition`. Then at the one call site (currently
    `addAttribute traceSpan attrMessagingDestinationPartitionId p` at line
    377), change the key to `attrShibuyaPartition`. Delete the standalone
    `addEvent traceSpan (mkEvent eventHandlerException [])` line (409) —
    the `recordException` call above it is sufficient.

Commands to run at the end of the milestone:

    cabal build shibuya-core
    cabal test shibuya-core-test
    nix fmt

Expected outcome: clean build, all existing tests pass (no new tests yet),
`git diff` shows only the expected edits.

Acceptance: `grep -n 'messaging.destination.partition.id'
shibuya-core/src/` returns nothing. `grep -n 'AttributeKey "' shibuya-core/src/`
still only matches inside `Semantic.hs` comments or Haddock.

### Milestone 2 — Give the per-message span a conventions-compliant name and operation

Scope: make the per-message span's `name` follow the messaging convention
`<destination> process` and always carry `messaging.operation=process` and
`messaging.destination.name=<processor id>`. The span's *attributes* gain
two new entries; the span's *name* changes from the constant
`"shibuya.process.message"` to a per-processor string. Nothing else in
the runtime behavior changes.

Work:

1.  In `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`, replace the
    constant `processMessageSpanName :: Text` with a function

        processSpanName :: Text -> Text
        processSpanName destination = destination <> " process"

    and update its Haddock to reference the upstream guidance that
    messaging span names should be `"<destination> <operation>"`. Keep the
    old `processMessageSpanName` constant exported as a backward-compat
    alias pointing at `processSpanName "shibuya"` only if any caller
    outside the repo might import it — since this crate is pre-release
    (`CLAUDE.md` notes version 0.1.0.0), it is acceptable to drop the
    old name entirely. Record that choice in the Decision Log when
    making it.
2.  In `shibuya-core/src/Shibuya/Runner/Supervised.hs`:
    -   `processOne`'s signature currently takes `TVar ProcessorMetrics`,
        `Int`, `IORef (Maybe HaltReason)`, `Handler es msg`,
        `Ingested es msg`. Add a `ProcessorId` parameter at the second
        position (between the `TVar` and the `Int`). The `ProcessorId`
        newtype is imported from `Shibuya.Runner.Metrics`.
    -   Update the two call sites of `processOne` (search with
        `grep -n processOne shibuya-core/src/Shibuya/Runner/Supervised.hs`)
        to pass the relevant `ProcessorId` — it is already available in
        scope in both `runSupervised` and `runWithMetrics` via the
        `ProcessorMetrics` record or the surrounding binding.
    -   Inside `processOne`, replace

            withSpan' processMessageSpanName consumerSpanArgs $ \traceSpan -> do

        with

            let ProcessorId pidText = procId
            withSpan' (processSpanName pidText) consumerSpanArgs $ \traceSpan -> do

        and immediately after the existing `addAttribute traceSpan
        attrMessagingSystem ("shibuya" :: Text)` line, add

            addAttribute traceSpan attrMessagingDestinationName pidText
            addAttribute traceSpan attrMessagingOperation ("process" :: Text)
3.  Re-run `cabal build shibuya-core` and `cabal test shibuya-core-test`.

Acceptance at the end of this milestone: a quick ad-hoc run of the
pgmq example (see the Validation section for the exact commands) and a
look at Jaeger at `http://127.0.0.1:16686` shows a span named like
`"shibuya-consumer process"` (not `"shibuya.process.message"`) with the
attributes `messaging.operation=process` and
`messaging.destination.name=shibuya-consumer`.

### Milestone 3 — Prove the conventions are honored with a unit test and refresh the docs

Scope: add a focused spec that records a span through `processOne` and
asserts against the *wire names* of the attributes and the span name.
This is the guarantee that future renames in
`hs-opentelemetry-semantic-conventions` will break compilation *and*
this test.

Work:

1.  Create `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`. It
    must:
    -   Build an in-memory span exporter using
        `hs-opentelemetry-exporter-in-memory` (see
        `OPENTELEMETRY_INTEGRATION.md`'s "In-Memory Exporter Helper"
        section for the pattern).
    -   Construct a fake `Ingested` with a `MessageId "m-1"`, no
        partition, no trace headers, and a user handler returning
        `AckOk`.
    -   Run `processOne` under `runTracing tracer` with a known
        `ProcessorId "test-proc"`.
    -   Read back the finished spans from the in-memory exporter.
    -   Assert exactly one span, whose name is `"test-proc process"`.
    -   Assert that its attribute map contains
        `messaging.system = "shibuya"`, `messaging.message.id = "m-1"`,
        `messaging.destination.name = "test-proc"`,
        `messaging.operation = "process"`, `shibuya.ack.decision =
        "ack_ok"`, `shibuya.inflight.count = 1`, and
        `shibuya.inflight.max = 1`.
    -   Assert that the span carries a `shibuya.handler.started` event
        and a `shibuya.handler.completed` event (by name only; the
        timing is not the point).
2.  Register this spec in the test suite driver
    (`shibuya-core/test/Spec.hs` or equivalent; check what pattern the
    other specs use — `grep -l 'Telemetry' shibuya-core/test` shows
    `EffectSpec.hs` and `PropagationSpec.hs`, so the driver either
    auto-discovers via `hspec-discover` or lists modules explicitly;
    follow whichever pattern is in use).
3.  In `docs/plans/OPENTELEMETRY_INTEGRATION.md`, add a short paragraph
    under "Semantic conventions" noting that attribute-key strings are
    now imported from `OpenTelemetry.SemanticConventions` rather than
    hand-written, and linking to this plan
    (`docs/plans/2-align-opentelemetry-semantic-conventions.md`).

Commands:

    nix fmt
    cabal build shibuya-core
    cabal test shibuya-core-test
    nix flake check

Acceptance: `cabal test shibuya-core-test` shows the new `SemanticSpec`
passing; `nix flake check` is clean.


## Concrete Steps

Working directory for every command in this section is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, unless stated.

Preparing:

    git status
    # Expect: only "M mori.dhall" (no in-flight telemetry edits)
    git rev-parse --abbrev-ref HEAD
    # Expect: master

Milestone 1 — the edit:

    # 1. Add dep.
    $EDITOR shibuya-core/shibuya-core.cabal
    # Insert "  , hs-opentelemetry-semantic-conventions" under the
    # existing "  , hs-opentelemetry-api ^>=0.3," line in the library
    # section's build-depends.

    # 2. Rewrite Semantic.hs.
    $EDITOR shibuya-core/src/Shibuya/Telemetry/Semantic.hs
    # Apply the edits described in "Plan of Work" Milestone 1.

    # 3. Fix the single call site.
    $EDITOR shibuya-core/src/Shibuya/Runner/Supervised.hs

    # 4. Build and test.
    cabal build shibuya-core
    cabal test shibuya-core-test

    # 5. Format.
    nix fmt

    # 6. Commit.
    git add shibuya-core/shibuya-core.cabal \
            shibuya-core/src/Shibuya/Telemetry/Semantic.hs \
            shibuya-core/src/Shibuya/Runner/Supervised.hs
    git commit  # message below

Commit message for Milestone 1:

    refactor(telemetry): derive OTel attribute keys from hs-opentelemetry-semantic-conventions

    Use the typed AttributeKey values exported by
    OpenTelemetry.SemanticConventions as the authoritative source for
    messaging.* attribute names. Drop the non-existent
    "messaging.destination.partition.id" key and replace its single
    call site with a shibuya-namespaced "shibuya.partition". Rename
    handler events into the shibuya.* namespace and drop the
    redundant custom exception event in favor of OTel.recordException.

    ExecPlan: docs/plans/2-align-opentelemetry-semantic-conventions.md
    Intention: intention_01kpgjfhrfe499b5vtpa043pyx

Milestone 2 — the edit:

    # 1. Rename processMessageSpanName to processSpanName :: Text -> Text.
    $EDITOR shibuya-core/src/Shibuya/Telemetry/Semantic.hs

    # 2. Thread ProcessorId through processOne and set messaging.operation.
    $EDITOR shibuya-core/src/Shibuya/Runner/Supervised.hs

    # 3. Build and test.
    cabal build shibuya-core
    cabal test shibuya-core-test
    nix fmt

    # 4. Commit.
    git add shibuya-core/src/Shibuya/Telemetry/Semantic.hs \
            shibuya-core/src/Shibuya/Runner/Supervised.hs
    git commit

Commit message for Milestone 2:

    feat(telemetry): name per-message spans "<destination> process" and set messaging.operation

    Follow the OpenTelemetry messaging semantic convention for span
    names — "<destination name> <operation>" — and always emit
    messaging.destination.name and messaging.operation=process on the
    consumer span. Thread the ProcessorId through processOne so the
    destination name matches the processor's identifier.

    ExecPlan: docs/plans/2-align-opentelemetry-semantic-conventions.md
    Intention: intention_01kpgjfhrfe499b5vtpa043pyx

Milestone 3 — the edit:

    # 1. Add SemanticSpec.hs.
    $EDITOR shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs

    # 2. If the test driver lists modules explicitly, add the module
    #    name; if hspec-discover is in use, the new file is picked up
    #    automatically.
    grep -l hspec-discover shibuya-core/shibuya-core.cabal shibuya-core/test

    # 3. Update the integration doc.
    $EDITOR docs/plans/OPENTELEMETRY_INTEGRATION.md

    # 4. Build and test everything.
    cabal build all
    cabal test shibuya-core-test
    nix flake check
    nix fmt

    # 5. Commit.
    git add shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs \
            docs/plans/OPENTELEMETRY_INTEGRATION.md
    # And whatever driver file needed updating (if any).
    git commit

Commit message for Milestone 3:

    test(telemetry): assert conventions-compliant attribute names on processOne spans

    Add a focused HSpec test that exercises processOne end-to-end
    against an in-memory span exporter and asserts the wire names
    of the messaging.* attributes, the span name, and the
    shibuya.handler.* event names. This is the guard that catches
    any future drift between our emitted names and the upstream
    spec.

    ExecPlan: docs/plans/2-align-opentelemetry-semantic-conventions.md
    Intention: intention_01kpgjfhrfe499b5vtpa043pyx


## Validation and Acceptance

After Milestone 3 is committed, validate end-to-end against a real collector.

1.  Make sure PostgreSQL and Jaeger are running as the project
    `CLAUDE.md` documents. Working directory is
    `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

        pg_ctl start -l $PGHOST/postgres.log
        ~/.local/bin/jaeger > /tmp/jaeger.log 2>&1 &

2.  Set tracing env vars and run the consumer:

        export OTEL_TRACING_ENABLED=true
        export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
        export OTEL_SERVICE_NAME=shibuya-consumer
        cabal run shibuya-pgmq-example:consumer

3.  In another terminal with the same env vars, push a message through
    the simulator (or enqueue one manually into the `shibuya` database).

4.  Hit the Jaeger API and confirm the span name and attributes:

        curl -s "http://127.0.0.1:16686/api/traces?service=shibuya-consumer&limit=1" \
          | jq '.data[0].spans[] | {name: .operationName, tags: (.tags | map({key,value}))}'

    Acceptance observations:

    -   Exactly one span per message has `operationName` matching the
        pattern `"<processor-id> process"` (the processor id is
        whatever the example sets — check
        `shibuya-pgmq-example/app/Consumer.hs` for the `ProcessorId`
        value).
    -   That span's tags include `messaging.system=shibuya`,
        `messaging.destination.name=<processor-id>`,
        `messaging.operation=process`,
        `messaging.message.id=<some uuid-like string>`.
    -   Tags do **not** include `messaging.destination.partition.id`
        (that string was removed).
    -   The span's events include `shibuya.handler.started` and
        `shibuya.handler.completed`, and no `handler.exception` event
        (but if the handler threw, a standard `exception` event with
        `exception.type`/`exception.message` is present — this is what
        `recordException` emits).

5.  Run the full test suite and formatter once more:

        cabal test shibuya-core-test
        nix flake check

    Both must succeed.


## Idempotence and Recovery

Every step is idempotent: re-editing `Semantic.hs`, `Supervised.hs`, or
`shibuya-core.cabal` and re-running `cabal build` and `cabal test`
converges on the same state. Nothing in this plan deletes or rewrites
anything outside the repository.

If a commit fails because of the treefmt pre-commit hook (the project's
`CLAUDE.md` warns about this), the fix is the one the project already
documents: `nix fmt`, re-stage the files, commit again.

If the new dependency `hs-opentelemetry-semantic-conventions` fails to
resolve:

-   Confirm the package is available in the repository's flake with
    `nix develop -c ghc-pkg list hs-opentelemetry-semantic-conventions`
    (inside the devShell). If missing, the local
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` flake
    exposes it; the fix is to add or update its overlay in this
    project's `flake.nix` so it is picked up by the Haskell package
    set. Do not `cabal install` it globally — that would bypass the
    nix-managed toolchain.

If at any point `cabal test shibuya-core-test` fails, stop and inspect
the test output; do not paper over failures by skipping the test or
pinning to older keys. The point of the plan is to align the emitted
names with the spec; a test regression is a real signal.


## Interfaces and Dependencies

Packages used:

-   `hs-opentelemetry-api` (already depended on) — supplies
    `AttributeKey`, `Attribute`, `Span`, `SpanArguments`, `Tracer`.
-   `hs-opentelemetry-semantic-conventions` (new dependency) —
    supplies the typed `AttributeKey`s for every name in this plan.
    Lives locally at
    `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions`.
-   `hs-opentelemetry-exporter-in-memory` (test-only dependency,
    possibly new) — used by the new `SemanticSpec.hs`. If it is not
    already in `shibuya-core.cabal`'s test stanza, add it there.

Interface shape at the end of each milestone:

-   End of Milestone 1:

        -- shibuya-core/src/Shibuya/Telemetry/Semantic.hs
        attrMessagingSystem            :: Text
        attrMessagingMessageId         :: Text
        attrMessagingDestinationName   :: Text
        attrMessagingOperation         :: Text          -- NEW
        attrShibuyaProcessorId         :: Text
        attrShibuyaInflightCount       :: Text
        attrShibuyaInflightMax         :: Text
        attrShibuyaAckDecision         :: Text
        attrShibuyaPartition           :: Text          -- replaces the deleted partition.id
        eventHandlerStarted            :: Text          -- value now "shibuya.handler.started"
        eventHandlerCompleted          :: Text          -- value now "shibuya.handler.completed"
        eventAckDecision               :: Text          -- value now "shibuya.ack.decision"
        -- eventHandlerException is deleted.
        -- attrMessagingDestinationPartitionId is deleted.

-   End of Milestone 2:

        -- shibuya-core/src/Shibuya/Telemetry/Semantic.hs
        processSpanName :: Text -> Text

        -- shibuya-core/src/Shibuya/Runner/Supervised.hs
        processOne
          :: (IOE :> es, Tracing :> es)
          => TVar ProcessorMetrics
          -> ProcessorId                -- NEW
          -> Int
          -> IORef (Maybe HaltReason)
          -> Handler es msg
          -> Ingested es msg
          -> Eff es ()

-   End of Milestone 3: no public interface change. The new test file
    exists; the integration doc has a short note linking here.

No other public APIs change. No adapter package needs to be modified
because none of them reference
`attrMessagingDestinationPartitionId`, `processMessageSpanName`, or
the old event names (grep confirms).

---

Revision history:

-   2026-04-21: Initial draft of this ExecPlan. Scoped to aligning the
    current hand-written attribute/event strings with the upstream
    OTel semantic conventions, keeping shibuya-namespaced attributes
    for genuinely non-spec concepts. Intention
    `intention_01kpgjfhrfe499b5vtpa043pyx` attached.

-   2026-04-21 (revision): Cross-referenced
    `OpenTelemetry-hw-kafka-client-Instrumentation-Guide.md` before
    starting implementation. Two updates:
    (1) Decision Log entry for `messaging.operation` corrected — the
    initial draft incorrectly claimed hw-kafka-client tags consumer
    polls with `messaging.operation="receive"`; the guide actually
    documents `"process"`. The corrected entry now positions our
    `"process"` choice as directly aligned with the worked example,
    and clarifies that Shibuya's per-message span wraps actual
    handler execution (so the `"process"` label is more faithful for
    us than for hw-kafka-client, whose own guide notes its consumer
    span only covers the poll call).
    (2) Added a new Decision Log entry recording that we follow the
    OTel-spec span-name order `"<destination> <operation>"` rather
    than hw-kafka-client's `"<operation> <destination>"` order, and
    explaining why.
    Surprises & Discoveries section now records both findings with
    citations. Purpose / Big Picture clarified to match. No
    implementation steps changed.
