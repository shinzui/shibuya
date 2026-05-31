---
id: 10
slug: upgrade-to-hs-opentelemetry-1-0
title: "Upgrade to hs-opentelemetry 1.0.0"
kind: exec-plan
created_at: 2026-05-20T00:51:48Z
intention: "intention_01ks1dpg2tenpvr2ym4xd052db"
---

# Upgrade to hs-opentelemetry 1.0.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shibuya's tracing code currently targets the `hs-opentelemetry-api` 0.3.x line.
The earlier version of this plan targeted the unreleased 0.4 branch, but upstream
has now released that work as the **1.0.0.0** `hs-opentelemetry-*` ecosystem.
This plan upgrades Shibuya to the 1.0 release while keeping the existing Shibuya
tracing API stable for downstream Haskell callers.

After this work, a user can build and test `shibuya-core` against
`hs-opentelemetry-api ^>= 1.0`, `hs-opentelemetry-propagator-w3c ^>= 1.0`,
`hs-opentelemetry-exporter-in-memory ^>= 1.0` for tests, and the newest Haskell
semantic-conventions package shipped with the 1.0 release,
`hs-opentelemetry-semantic-conventions ^>= 1.40`. Shibuya's emitted messaging
attributes will follow the latest packaged typed semantic-convention keys rather
than hand-written strings. The visible change is that `messaging.operation` is
replaced by `messaging.operation.type = "process"`, matching the current
OpenTelemetry messaging span convention. The live OpenTelemetry documentation on
2026-05-31 advertises semantic conventions **1.41.0**, while the Haskell 1.0
release's generated semantic-conventions package is **1.40.0.0**. This plan
therefore requires two checks: use the newest available Haskell package now, and
audit the small Shibuya messaging key set against the live 1.41.0 docs so any
gap is explicit rather than accidental.

The outcome is observable in three ways. First, `cabal build all` and
`cabal test shibuya-core-test` pass. Second, the telemetry specs prove that
`processOne` emits a Consumer span named `"<processor-id> process"` with
`messaging.system`, `messaging.destination.name`, `messaging.message.id`, and
`messaging.operation.type`. Third, a Jaeger smoke test shows the example app
exporting spans under service `shibuya-consumer` with the same attributes.

This is not a broad observability rewrite. Do not adopt the new metrics API, logs
exporters, `OpenTelemetry.SDK.withOpenTelemetry`, exception-handler policy, or
new propagators in this plan. Those are useful follow-ups, but the goal here is
to move the existing trace behavior to 1.0.0.0 with a small, reviewable diff.


## Progress

Use this checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into
two items.

- [x] 2026-05-31: Re-scoped this plan from the unreleased 0.4 branch to the released
  1.0.0.0 ecosystem after reviewing the local 1.0 upgrade guide, upstream migration
  guide, package cabal files, generated semantic-conventions source, and the live
  OpenTelemetry semantic-conventions pages.
- [x] 2026-05-31: M0. Pre-flight confirmed Cabal sees the 1.0.0.0 packages from
  the upstream release tag after replacing the stale source-repository-package pin
  with `hs-opentelemetry-api-types-1.0.0.0` and adding the `api-types` subdir.
- [x] 2026-05-31: M1. Bumped `shibuya-core/shibuya-core.cabal` bounds for the
  OpenTelemetry API, W3C propagator, in-memory exporter, and
  semantic-conventions packages.
- [x] 2026-05-31: M2. Updated source code and tests for the 1.0 API changes,
  including token-based context detach, timeout-aware tracer-provider shutdown,
  the new OpenTelemetry `Base` type in propagation tests, and the `ImmutableSpan`
  hot-field accessors in semantic tests.
- [x] 2026-05-31: M3. Updated `Shibuya.Telemetry.Semantic` and tests to use
  `messaging_operation_type` and assert `messaging.operation.type`.
- [x] 2026-05-31: M4. Audited Shibuya's emitted messaging attributes against
  `hs-opentelemetry-semantic-conventions-1.40.0.0` and live OpenTelemetry
  semantic conventions 1.41.0. The Haskell package covers all four Shibuya keys;
  the live docs additionally require `messaging.operation.name`, which remains
  intentionally omitted at the generic framework layer until adapters can supply
  a system-specific value.
- [ ] M5. Run `cabal build all`, `cabal test shibuya-core-test`, `nix fmt`, and
  `nix flake check`; fix any fallout.
- [ ] M6. Re-run the live Jaeger smoke test and capture one span proving
  `messaging.operation.type=process`.
- [ ] M7. Update `shibuya-core/CHANGELOG.md` and decide the Shibuya version bump.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The local `hs-opentelemetry` corpus has already replaced the old
  `OpenTelemetry-0.4-Upgrade-Guide.md` with `docs/OpenTelemetry-1.0-Upgrade-Guide.md`.
  That guide states that the 0.4 branch shipped as 1.0.0.0, with all non-semantic
  packages moving together to `1.0.0.0` and `hs-opentelemetry-semantic-conventions`
  versioned separately as `1.40.0.0`.
  Evidence:
  ```text
  hs-opentelemetry/api/hs-opentelemetry-api.cabal: version: 1.0.0.0
  hs-opentelemetry/propagators/w3c/hs-opentelemetry-propagator-w3c.cabal: version: 1.0.0.0
  hs-opentelemetry/exporters/in-memory/hs-opentelemetry-exporter-in-memory.cabal: version: 1.0.0.0
  hs-opentelemetry/semantic-conventions/hs-opentelemetry-semantic-conventions.cabal: version: 1.40.0.0
  ```

- Observation: The live OpenTelemetry documentation on 2026-05-31 is already at
  semantic conventions 1.41.0, but the Haskell generated package in the 1.0.0.0
  release tracks semantic conventions 1.40.0.0. Shibuya must therefore treat
  `^>= 1.40` as the latest available Haskell typed package and separately audit
  the four emitted messaging keys against the live 1.41.0 docs.
  Evidence:
  ```text
  https://opentelemetry.io/docs/specs/semconv/ title: OpenTelemetry semantic conventions 1.41.0
  semantic-conventions/hs-opentelemetry-semantic-conventions.cabal description: generated based on semantic-conventions v1.40
  ```

- Observation: The existing `cabal.project` pin
  `adc464b0a45e56a983fa1441be6e432b50c29e0e` predates the new
  `api-types` subdirectory, so adding `api-types` to the subdir list failed until
  the source-repository-package tag was changed to the upstream
  `hs-opentelemetry-api-types-1.0.0.0` release tag.
  Evidence:
  ```text
  api-types: getDirectoryContents:openDirStream: does not exist (No such file or directory)
  HEAD is now at 46a42cd Fix hs-opentelemetry-api sdist packaging
  hs-opentelemetry-api-types-1.0.0.0 (lib) (requires build)
  hs-opentelemetry-semantic-conventions-1.40.0.0 (lib) (requires build)
  hs-opentelemetry-api-1.0.0.0 (lib) (requires build)
  hs-opentelemetry-exporter-in-memory-1.0.0.0 (lib) (requires build)
  hs-opentelemetry-propagator-w3c-1.0.0.0 (lib) (requires build)
  ```

- Observation: `hs-opentelemetry-api` 1.0 changed two test-facing APIs beyond the
  planned `attachContext` and `shutdownTracerProvider` changes. `Trace.Id` now
  exports its own `Base(..)` constructor for `Base16`, and ended span data stores
  mutable fields behind `spanHot`, read with `hotName`, `hotAttributes`, and
  `hotEvents`.
  Evidence:
  ```text
  Couldn't match expected type OTel.Id.Base with actual type Base
  Variable not in scope: spanName :: ImmutableSpan -> a0
  Variable not in scope: spanAttributes :: ImmutableSpan -> Attributes
  Variable not in scope: spanEvents :: ImmutableSpan -> AppendOnlyBoundedCollection Event
  ```

- Observation: The 1.0 W3C trace-context parser is stricter than the older test
  expectations. Non-`00` traceparent versions and all-zero trace or span IDs now
  decode to `Nothing`, so Shibuya's tests were updated to assert rejection. Also,
  `currentTraceHeaders` needs a tracer provider with at least one span processor
  in the test because upstream skips thread-local context modification on the
  no-processor fast path.
  Evidence:
  ```text
  Shibuya.Telemetry.Propagation.extractTraceContext rejects traceparent with non-standard version [OK]
  Shibuya.Telemetry.Propagation.extractTraceContext rejects traceparent with all-zero trace ID [OK]
  Shibuya.Telemetry.Propagation.extractTraceContext rejects traceparent with all-zero span ID [OK]
  Shibuya.Telemetry.Propagation.currentTraceHeaders returns headers carrying the active span's traceparent [OK]
  ```

- Observation: The semantic-conventions audit confirmed that the Haskell 1.40
  generated source has typed keys for all Shibuya generic messaging attributes:
  `messaging.system`, `messaging.destination.name`, `messaging.message.id`, and
  `messaging.operation.type`. It also has `messaging.operation.name`, but Shibuya
  does not emit it because the live 1.41.0 documentation defines it as the
  system-specific operation name and generic `shibuya-core` only knows the
  cross-system operation type `process`.
  Evidence:
  ```text
  messaging_destination_name = AttributeKey "messaging.destination.name"
  messaging_message_id = AttributeKey "messaging.message.id"
  messaging_operation_type = AttributeKey "messaging.operation.type"
  messaging_operation_name = AttributeKey "messaging.operation.name"
  messaging_system = AttributeKey "messaging.system"
  Deprecated, use @messaging.operation.type@ instead.
  messaging_operation = AttributeKey "messaging.operation"
  OpenTelemetry semantic conventions 1.41.0 docs: messaging.operation.name is Required; messaging.operation.type is Conditionally Required if applicable; messaging.message.id is Recommended for single-message spans.
  ```


## Decision Log

Record every decision made while working on the plan.

- Decision: Rename this plan from `upgrade-to-hs-opentelemetry-0-4` to
  `upgrade-to-hs-opentelemetry-1-0` while preserving `id: 10` and the existing
  intention id.
  Rationale: The upstream 0.4 branch was released as 1.0.0.0. Keeping the old title
  would send future implementers toward stale bounds and stale Hackage/source-pin
  assumptions.
  Date: 2026-05-31

- Decision: Target `hs-opentelemetry-api ^>= 1.0`,
  `hs-opentelemetry-propagator-w3c ^>= 1.0`,
  `hs-opentelemetry-exporter-in-memory ^>= 1.0`, and
  `hs-opentelemetry-semantic-conventions ^>= 1.40`.
  Rationale: Local upstream cabal files for API, W3C propagator, in-memory exporter,
  and API types all declare `version: 1.0.0.0`. The semantic-conventions package
  deliberately follows the OpenTelemetry semantic-conventions spec version and
  declares `version: 1.40.0.0`.
  Date: 2026-05-31

- Decision: Adopt `messaging.operation.type` for Shibuya's `"process"` value and
  keep the exported Haskell name `attrMessagingOperation`.
  Rationale: The generated Haskell source exposes
  `messaging_operation_type :: AttributeKey Text` with wire string
  `"messaging.operation.type"` and marks the old `messaging_operation` key
  deprecated. The current OpenTelemetry messaging span documentation says
  `messaging.operation.type` identifies the operation type and lists `process` as a
  well-known value. Preserving the Shibuya Haskell symbol avoids a downstream source
  break while still changing the wire key to the current convention.
  Date: 2026-05-31

- Decision: Do not emit `messaging.operation.name` from Shibuya's generic framework
  span in this upgrade.
  Rationale: The live 1.41.0 messaging convention makes `messaging.operation.name`
  the system-specific operation name, while `messaging.operation.type` is the
  low-cardinality cross-system type. Shibuya knows it is processing a message, so
  `"process"` belongs in the type field. It does not know a broker-specific action
  such as Kafka `poll`, RabbitMQ `consume`, or an adapter-specific ack operation at
  the generic `shibuya-core` layer. Individual adapters can add
  `messaging.operation.name` when they know that system-specific name.
  Date: 2026-05-31

- Decision: Keep `makeTracer` in `runTracingNoop` and test helpers unless a compile
  error proves it must change; use monadic `OTel.getTracer` only where caching is
  worth the local churn.
  Rationale: The 1.0 migration guide says `getTracer` is now monadic and cached, but
  upstream `OpenTelemetry.Trace.Core` still exports pure `makeTracer` as a lower-level
  helper. Shibuya already stores a `Tracer`, so switching every construction site to
  `getTracer` is optional rather than required for this minimal upgrade.
  Date: 2026-05-31

- Decision: Update every test `shutdownTracerProvider provider` call to
  `shutdownTracerProvider provider (Just 5_000_000)` or `Nothing`.
  Rationale: In 1.0, shutdown is timeout-aware and returns a `ShutdownResult`.
  Passing five seconds matches the upstream migration-guide example and keeps tests
  deterministic without changing assertions.
  Date: 2026-05-31

- Decision: Do not adopt metrics, logs, `OpenTelemetry.SDK.withOpenTelemetry`,
  exception-handler configuration, Jaeger/X-Ray propagators, or baggage-size
  enforcement in this plan.
  Rationale: Shibuya's current direct OpenTelemetry surface is tracing, W3C trace
  context propagation, and typed messaging attributes. Expanding the plan to new
  signals would make the upgrade harder to review and would not be required to
  preserve existing behavior.
  Date: 2026-05-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shibuya is a Haskell queue-processing framework. The `shibuya-core` library creates
one OpenTelemetry span for each processed message in
`shibuya-core/src/Shibuya/Runner/Supervised.hs`, but most OpenTelemetry imports are
wrapped behind small modules so the rest of the framework does not depend on the
OpenTelemetry API directly.

The repository-relative files that matter for this upgrade are:

- `shibuya-core/shibuya-core.cabal`, where dependency bounds for
  `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`,
  `hs-opentelemetry-semantic-conventions`, and the test-only
  `hs-opentelemetry-exporter-in-memory` are declared.
- `shibuya-core/src/Shibuya/Telemetry/Effect.hs`, which defines the `Tracing`
  effect, stores the current `OTel.Tracer`, creates a no-op tracer, wraps actions in
  `OTel.inSpan`, and temporarily attaches an extracted parent span context via
  `Ctx.attachContext` / `Ctx.detachContext`.
- `shibuya-core/src/Shibuya/Telemetry/Propagation.hs`, which uses the W3C
  propagator's `decodeSpanContext` and `encodeSpanContext` helpers. The signatures
  are unchanged in 1.0 for the way Shibuya uses them.
- `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`, which turns typed semantic
  convention `AttributeKey` values into Shibuya's exported wire-string constants.
- `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`, which uses the in-memory
  exporter to assert exactly which attributes are on an emitted processing span.
- `shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs`, which creates and
  shuts down tracer providers in propagation tests.

Term glossary:

`hs-opentelemetry` is the Haskell OpenTelemetry ecosystem maintained at
`https://github.com/iand675/hs-opentelemetry`. A local corpus is registered in `mori`
as `iand675/hs-opentelemetry` with source under
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry`.

`hs-opentelemetry-api` is the package defining tracing data types and functions such
as `Tracer`, `Span`, `SpanContext`, `inSpan`, `createTracerProvider`,
`makeTracer`, `getTracer`, and `shutdownTracerProvider`.

`hs-opentelemetry-api-types` is a leaf package introduced by upstream so both the API
and semantic-conventions packages can depend on `Attribute` and `AttributeKey`
without a dependency cycle. Shibuya does not need to import it directly.

`hs-opentelemetry-semantic-conventions` is generated from OpenTelemetry's semantic
conventions model. In the Haskell 1.0 release it is version `1.40.0.0` and exports
one module, `OpenTelemetry.SemanticConventions`.

`messaging.operation.type` is the current low-cardinality OpenTelemetry messaging
attribute for operation types such as `send`, `receive`, and `process`.
`messaging.operation.name` is for a system-specific operation name such as an
adapter's broker verb. `messaging.operation` is the deprecated legacy key.


## Plan of Work

The work breaks into eight milestones. Each milestone should leave the tree in a
known state and record evidence in the living sections when commands are run.

### M0 - Resolve package source

Run the following commands from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`
to see whether Hackage can resolve the 1.0 packages:

```bash
cabal update
cabal build --dry-run shibuya-core 2>&1 | tail -40
```

If Cabal sees `hs-opentelemetry-api-1.0.0.0` and the matching propagator and exporter
packages, do not add a source pin. If Hackage still exposes only older versions,
create or update top-level `cabal.project` with a `source-repository-package` stanza
pinning the upstream repo at the release commit. The local corpus shows
`f8956f9 docs: replace 0.4 upgrade guide with 1.0 guide; align guides to 1.0 API`
and `66e6343 Merge upstream hs-opentelemetry 1.0.0.0 into subtree`; prefer an
upstream release tag or exact upstream commit if available rather than a moving branch.

The stanza must include every subdirectory Cabal needs:

```cabal
source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry.git
  tag: <1.0.0.0-release-commit-or-tag>
  subdir:
    api
    api-types
    propagators/w3c
    semantic-conventions
    exporters/in-memory
```

Acceptance: Cabal's dry-run install plan includes `hs-opentelemetry-api-1.0.0.0`,
`hs-opentelemetry-api-types-1.0.0.0`,
`hs-opentelemetry-propagator-w3c-1.0.0.0`,
`hs-opentelemetry-exporter-in-memory-1.0.0.0`, and
`hs-opentelemetry-semantic-conventions-1.40.0.0`.

### M1 - Bump Cabal bounds

Edit `shibuya-core/shibuya-core.cabal`. In the library stanza, change:

```cabal
hs-opentelemetry-api ^>=0.3,
hs-opentelemetry-propagator-w3c ^>=0.1,
hs-opentelemetry-semantic-conventions ^>=0.1,
```

to:

```cabal
hs-opentelemetry-api ^>=1.0,
hs-opentelemetry-propagator-w3c ^>=1.0,
hs-opentelemetry-semantic-conventions ^>=1.40,
```

In the test-suite stanza, change:

```cabal
hs-opentelemetry-exporter-in-memory ^>=0.0,
```

to:

```cabal
hs-opentelemetry-exporter-in-memory ^>=1.0,
```

Keep `hs-opentelemetry-api` in the test-suite stanza. It can remain unbounded there
because the test suite depends on the local library, which already constrains the
selected API version.

### M2 - Update 1.0 API call sites

In `shibuya-core/src/Shibuya/Telemetry/Effect.hs`, replace the `bracket_` import with
`bracket` and change `withExtractedContext` to pass the token from attach to detach:

```haskell
withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
  bracket
    (Ctx.attachContext newContext)
    Ctx.detachContext
    (\_token -> runInIO action)
```

Do not change the exported type of `withExtractedContext`. The `Token` is only an
implementation detail required by the 1.0 context API.

In tests, every `shutdownTracerProvider provider` call must receive a timeout:

```haskell
_ <- shutdownTracerProvider provider (Just 5_000_000)
```

Use `Nothing` only if a test explicitly wants the library default timeout. There are
current calls in `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` and
`shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs`.

If the build reports that pure `makeTracer` still compiles, leave it in place. If a
future 1.0.0.x package removes it, switch the test helpers and `runTracingNoop` to
monadic `OTel.getTracer` and record that surprise.

### M3 - Adopt current messaging semantic keys

In `shibuya-core/src/Shibuya/Telemetry/Semantic.hs`, keep the exported Shibuya symbol
`attrMessagingOperation` but make it derive from the new typed key:

```haskell
-- | The messaging operation type (@messaging.operation.type@).
--
-- One of the spec-defined enum values: @create@, @send@, @receive@,
-- @process@, @settle@. Shibuya's per-message span uses @"process"@.
attrMessagingOperation :: Text
attrMessagingOperation = unkey Sem.messaging_operation_type
```

Also update any comment that still says semantic-conventions v1.24 or
`messaging.operation`.

In `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`, replace both assertions of
the legacy key:

```haskell
attrs `shouldHaveTextAttribute` ("messaging.operation", "process")
```

with:

```haskell
attrs `shouldHaveTextAttribute` ("messaging.operation.type", "process")
```

The file currently has an uncommitted local import change from
`OpenTelemetry.Exporter.InMemory.Span` to `OpenTelemetry.Exporter.InMemory`. Keep that
change because the 1.0 in-memory exporter exposes the barrel module
`OpenTelemetry.Exporter.InMemory`.

### M4 - Audit semantic conventions against latest docs

Use the generated Haskell source and the live OpenTelemetry docs to verify the exact
key set. From the project root, run:

```bash
rg -n "messaging_(system|destination_name|message_id|operation_type|operation_name|operation)" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Expected facts to confirm:

- `Sem.messaging_system` has wire string `"messaging.system"`.
- `Sem.messaging_destination_name` has wire string `"messaging.destination.name"`.
- `Sem.messaging_message_id` has wire string `"messaging.message.id"`.
- `Sem.messaging_operation_type` has wire string `"messaging.operation.type"`.
- `Sem.messaging_operation` still exists only as a deprecated key and should not be
  used by Shibuya.

Then compare against `https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/`.
As of 2026-05-31, that page says `messaging.operation.name` is required as the
system-specific name, `messaging.system` is required, `messaging.destination.name` is
conditionally required, `messaging.operation.type` is conditionally required if
applicable, and `messaging.message.id` is recommended for single-message spans. For
generic Shibuya framework spans, the implementation should emit the four keys it
knows and omit `messaging.operation.name` until an adapter can provide a
system-specific value.

Record the audit result in Surprises & Discoveries. If the Haskell package has
advanced past 1.40 by the time this plan is implemented, bump the cabal bound to the
newest available Haskell package and update this plan before continuing.

### M5 - Build, test, format, and flake check

Run:

```bash
cabal build all
cabal test shibuya-core-test
nix fmt
nix flake check
```

Acceptance: all commands exit 0. For `cabal test shibuya-core-test`, the semantic
spec must pass with the two `messaging.operation.type` assertions. If any command
fails, paste the command, exit code, and a concise excerpt into Surprises &
Discoveries before fixing it.

### M6 - Live Jaeger smoke test

Start Jaeger and run the example app:

```bash
~/.local/bin/jaeger > /tmp/jaeger.log 2>&1 &
sleep 2
curl -s "http://127.0.0.1:16686/api/services" | jq '.data'

OTEL_TRACING_ENABLED=true \
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318" \
OTEL_SERVICE_NAME="shibuya-consumer" \
cabal run shibuya-example
```

Then query one trace:

```bash
curl -s "http://127.0.0.1:16686/api/traces?service=shibuya-consumer&limit=1" \
  | jq '.data[0].spans[0].tags[] | select(.key == "messaging.operation.type")'
```

Expected output:

```json
{
  "key": "messaging.operation.type",
  "type": "string",
  "value": "process"
}
```

Paste the trimmed result into Surprises & Discoveries as evidence.

### M7 - Bookkeeping

Update `shibuya-core/CHANGELOG.md` with an entry describing:

- dependency bounds moving to `hs-opentelemetry-*` 1.0,
- `hs-opentelemetry-semantic-conventions` moving to the newest available Haskell
  generated package,
- the wire key rename from `messaging.operation` to `messaging.operation.type`, and
- the fact that dashboards and alert queries using the old key must be updated.

Decide the version bump by inspecting existing project convention:

```bash
git log --oneline -- shibuya-core/shibuya-core.cabal shibuya-core/CHANGELOG.md
```

Because the Haskell API is preserved but the emitted wire attribute changes, this is
at least a minor observable behavior change. If the project treats wire-format changes
as breaking, bump `0.5.0.0` to `0.6.0.0`; otherwise bump to `0.5.1.0`. Record the
decision in the Decision Log.


## Concrete Steps

The commands below assume the working directory is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

```bash
mori show --full
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
cabal update
cabal build --dry-run shibuya-core 2>&1 | tail -40
```

Edit `shibuya-core/shibuya-core.cabal`, then run:

```bash
cabal build --dry-run shibuya-core 2>&1 | tail -40
```

Edit `shibuya-core/src/Shibuya/Telemetry/Effect.hs`,
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs`,
`shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`, and
`shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs`, then run:

```bash
cabal build shibuya-core
cabal test shibuya-core-test
```

Run the semantic-conventions audit:

```bash
rg -n "messaging_(system|destination_name|message_id|operation_type|operation_name|operation)" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Finish with:

```bash
cabal build all
cabal test shibuya-core-test
nix fmt
nix flake check
```

Run the Jaeger smoke test from M6 and update `shibuya-core/CHANGELOG.md` plus the
version field in `shibuya-core/shibuya-core.cabal`.


## Validation and Acceptance

The plan is accepted when all of the following are true from the project root:

1. `cabal build all` exits 0.
2. `cabal test shibuya-core-test` exits 0. The semantic test asserts that emitted
   spans include `messaging.operation.type = "process"` and no longer asserts the
   deprecated `messaging.operation` key.
3. `nix fmt` has been run and `nix flake check` exits 0.
4. `rg -n "Sem\\.messaging_operation\\b|\"messaging\\.operation\"" shibuya-core`
   finds no live implementation or test assertion that still emits or expects the
   deprecated key. Documentation may mention the legacy key only when explaining the
   migration.
5. The semantic-conventions audit is recorded in Surprises & Discoveries, including
   the current Haskell package version and the live OpenTelemetry docs version checked
   on the implementation date.
6. The Jaeger smoke test evidence shows a span with
   `messaging.operation.type=process`.
7. `shibuya-core/CHANGELOG.md` calls out the OpenTelemetry 1.0 bounds and the
   wire-key rename.


## Idempotence and Recovery

Every step is a small text edit or a read-only validation command. Re-running Cabal
dry-runs, builds, tests, `nix fmt`, and `nix flake check` is safe. Re-running the
Jaeger smoke test creates additional trace data but does not mutate repository files.

If a Hackage upload appears while implementation is in progress, prefer the released
Hackage packages and remove any temporary `source-repository-package` stanza. If the
work started with a git pin and the upstream branch moves, do not re-pin midway
unless dependency resolution fails; finish the current upgrade on the chosen commit,
then update the pin in a separate follow-up.

Rollback is limited to the files touched by this plan:

```bash
git restore -SW cabal.project shibuya-core/shibuya-core.cabal \
  shibuya-core/src/Shibuya/Telemetry/Effect.hs \
  shibuya-core/src/Shibuya/Telemetry/Semantic.hs \
  shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs \
  shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs \
  shibuya-core/CHANGELOG.md
```

Do not run that rollback command if it would discard unrelated user work. Check
`git status --short` and `git diff` first, then restore individual hunks if needed.


## Interfaces and Dependencies

After the upgrade, Shibuya's OpenTelemetry package targets are:

| Package | Version target | Role |
|---|---|---|
| `hs-opentelemetry-api` | `^>= 1.0` | Tracing types and functions: `Tracer`, `Span`, `SpanContext`, `SpanArguments`, `SpanStatus`, `NewEvent`, `inSpan`, `inSpan'`, `addAttribute`, `addAttributes`, `addEvent`, `setStatus`, `recordException`, `wrapSpanContext`, `createTracerProvider`, `makeTracer`, `getTracer`, `shutdownTracerProvider`, and `emptyTracerProviderOptions`. |
| `hs-opentelemetry-api-types` | transitive `^>= 1.0` | `Attribute`, `PrimitiveAttribute`, and `AttributeKey`; used directly by semantic-conventions and re-exported by the API package. |
| `hs-opentelemetry-propagator-w3c` | `^>= 1.0` | W3C `traceparent` / `tracestate` encoding and decoding through `decodeSpanContext` and `encodeSpanContext`. |
| `hs-opentelemetry-semantic-conventions` | `^>= 1.40` unless a newer Haskell package exists when implemented | Typed generated keys for `messaging.system`, `messaging.destination.name`, `messaging.message.id`, and `messaging.operation.type`. |
| `hs-opentelemetry-exporter-in-memory` | `^>= 1.0` test-only | Captures spans into an `IORef [ImmutableSpan]` for test assertions. |

The Shibuya Haskell interfaces intended to remain stable are:

- `Shibuya.Telemetry.Effect.runTracing`, `runTracingNoop`, `withSpan`,
  `withSpan'`, `addAttribute`, `addAttributes`, `addEvent`, `recordException`,
  `setStatus`, `withExtractedContext`, `getTracer`, and `isTracingEnabled`.
- `Shibuya.Telemetry.Propagation.extractTraceContext`, `injectTraceContext`, and
  `currentTraceHeaders`.
- `Shibuya.Telemetry.Semantic.attrMessagingSystem`, `attrMessagingDestinationName`,
  `attrMessagingMessageId`, and `attrMessagingOperation`.

The wire interface intentionally changes: `attrMessagingOperation` now resolves to
`"messaging.operation.type"` instead of `"messaging.operation"`. Downstream code that
imports the Haskell symbol keeps compiling; dashboards and alert rules that query the
old wire key must be updated.

Revision note 2026-05-31: Rewrote the plan for the released hs-opentelemetry 1.0.0.0
ecosystem, renamed the file and frontmatter slug/title from 0.4 to 1.0, updated all
dependency targets, added 1.0-specific API fallout, and added an explicit semantic
conventions audit against both the Haskell 1.40 generated package and the live
OpenTelemetry 1.41.0 documentation because the user's requirement is to follow the
latest conventions, not merely compile against the new API.
