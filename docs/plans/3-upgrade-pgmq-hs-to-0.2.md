# Upgrade shibuya-pgmq-adapter to pgmq-hs 0.2.0.0

Intention: intention_01kg953t69enps79pj77taz6nw

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

`pgmq-hs` is the Haskell client library for PGMQ (PostgreSQL Message Queue). The
`shibuya-pgmq-adapter` package in this repository is a thin adapter that wires
pgmq-hs into the Shibuya queue-processing framework. The adapter currently pins
`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and `pgmq-migration` to the `^>=0.1`
series. Upstream has just released `0.2.0.0` of those packages
(2026-04-23) with two sets of user-visible breaking changes:

1.  **Error handling is now structured.** The old opaque
    `Pgmq.Effectful.PgmqError` / `PgmqPoolError UsageError` constructor has been
    replaced by `PgmqRuntimeError` with three structured constructors —
    `PgmqAcquisitionTimeout`, `PgmqConnectionError`, and `PgmqSessionError` —
    so callers can now inspect which layer of the hasql pool stack failed
    (waiting on a connection, opening a socket, executing a statement).
    A classification helper `isTransient` ships with it for retry logic.
    Legacy names remain as deprecated re-exports for one release, but the
    Error-effect type carried by `runPgmq` / `runPgmqTraced` is now
    `PgmqRuntimeError`, so code that spells the type explicitly in a
    `runError` / `runErrorNoCallStack` call will stop compiling.
2.  **OpenTelemetry attribute keys and span names now follow the
    OpenTelemetry semantic-conventions specification v1.24.** Previously the
    traced interpreter emitted span names like `"pgmq send"` with attribute
    `messaging.operation.type = "send"`. After the upgrade it emits span
    names like `"publish my-queue"` with `messaging.operation = "publish"`.
    Queue-management operations (create, drop, archive, set_vt, …) now
    emit `SpanKind.Internal` instead of `Producer`. Trace-context
    propagation is routed through the tracer provider's configured
    propagator (W3C by default, B3/Datadog swappable) instead of being
    hard-wired to W3C.

After this plan is implemented, a contributor who runs

    cabal build all

at the repo root will see all six packages rebuild cleanly against
`pgmq-*-0.2.0.0`, and someone who runs the example consumer with Jaeger
running locally will see traces whose span names match the upstream
messaging-spans spec (`"publish orders"`, `"receive orders"`, etc.) and whose
attribute keys match v1.24. The shibuya-pgmq-adapter library itself exposes
the same API as before — the upgrade is a dependency bump plus an error-type
rename; no public signatures change.

This matters because (a) pgmq-hs 0.2 is already the latest published
version, so sticking on 0.1 would compound with other packages in the
ecosystem that track pgmq-hs, and (b) the v1.24 conventions are what the
rest of Shibuya's own OTel emission (see
`docs/plans/2-align-opentelemetry-semantic-conventions.md`) was already
aligned with — this upgrade brings the pgmq layer of the trace into
agreement with the Shibuya layer of the trace, so a single trace in Jaeger
will read consistently from producer span through pgmq database call down
to the consumer processing span.

The demonstrable outcomes after completion:

1.  `cabal build all` succeeds with no warnings about deprecated `PgmqError`
    or `PgmqPoolError`.
2.  `cabal test shibuya-pgmq-adapter-test` passes (86 existing tests, no
    changes in count).
3.  Starting Jaeger (`~/.local/bin/jaeger`), starting PostgreSQL from the
    repo-local devShell, and running the example consumer
    (`cabal run shibuya-pgmq-consumer`) against a seeded queue produces
    spans in the Jaeger UI with names `"publish orders"` / `"receive
    orders"` (not `"pgmq send"` / `"pgmq read"`), with attribute
    `messaging.operation` set to `"publish"` or `"receive"`.
4.  `cabal.project.freeze` pins each of `pgmq-core`, `pgmq-effectful`,
    `pgmq-hasql`, `pgmq-migration` at `0.2.0.0`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into
two ("done" vs. "remaining"). This section must always reflect the actual
current state of the work.

- [x] M1.1 — Bump `pgmq-*` version bounds in
  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`:
  `pgmq-core ^>=0.1` → `^>=0.2`, `pgmq-effectful ^>=0.1` → `^>=0.2`,
  `pgmq-hasql ^>=0.1` → `^>=0.2`. Do the same for the test-suite stanza's
  `pgmq-migration` dep (currently unbounded but pulls 0.1.x from the
  freeze file). *(Done 2026-04-23.)*
- [x] M1.2 — Bump the same bounds in
  `shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal` (both the
  benchmark stanza and the `endurance-test` executable stanza).
  *(Done 2026-04-23.)*
- [x] M1.3 — Bump the same bounds in
  `shibuya-pgmq-example/shibuya-pgmq-example.cabal` (library, simulator,
  and consumer stanzas). *(Done 2026-04-23.)*
- [x] M1.4 — Update `cabal.project.freeze`: change each of the four
  `any.pgmq-* ==0.1.1.0` / `==0.1.0.0` lines to `==0.2.0.0`. Also bumped
  the `index-state` pin from `2026-02-24T02:38:45Z` to
  `2026-04-24T03:15:26Z` (the freeze file was capping the Hackage index
  at a date before pgmq-hs 0.2.0.0 was published; without the bump the
  solver only saw 0.1.x). *(Done 2026-04-23.)*
- [x] M1.5 — Attempt `cabal build all`. Recorded the expected compile error
  in Surprises & Discoveries — `app/Simulator.hs:229` is the first failure,
  citing "no handler for `Error Pgmq.Effectful.Interpreter.PgmqRuntimeError`",
  which confirms the only blocker to compilation is the call-site rename.
  *(Done 2026-04-23.)*
- [x] M2.1 — In `shibuya-pgmq-adapter/test/TestUtils.hs` replace the
  `PgmqError` imports and the `Error PgmqError` effect annotation on
  `runWithPool` with `PgmqRuntimeError`. *(Done 2026-04-23.)*
- [x] M2.2 — In `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`
  do the same for the `runAdapterIO` helper. *(Done 2026-04-23.)*
- [x] M2.3 — In `shibuya-pgmq-adapter-bench/bench/Bench/Raw.hs` do the same
  for `runEffectful` and the inline `runEff . runErrorNoCallStack @PgmqError`
  in `effReadBatch`. *(Done 2026-04-23.)*
- [x] M2.4 — In `shibuya-pgmq-adapter-bench/app/Endurance.hs` do the same
  for the `runEff $ runErrorNoCallStack @PgmqError $ runPgmq pool $ ...`
  call. *(Done 2026-04-23.)*
- [x] M2.5 — In `shibuya-pgmq-example/app/Simulator.hs` do the same for
  both `Either PgmqError ()` annotations. *(Done 2026-04-23.)*
- [x] M2.6 — In `shibuya-pgmq-example/app/Consumer.hs` do the same for the
  `runErrorNoCallStack @PgmqError $ runPgmqTraced pool tracer $ ...` call.
  *(Done 2026-04-23.)*
- [x] M2.6a — *(New step, surfaced during M2.7.)* In
  `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs` rename
  the import and the `Error PgmqError` annotation on its `runAdapterIO`
  helper. The plan's M2 file list missed this seventh call site. See
  Surprises & Discoveries. *(Done 2026-04-23.)*
- [x] M2.6b — *(New step, surfaced during M2.7.)* In
  `shibuya-pgmq-example/app/Simulator.hs`, both `sendMessageTraced`
  call sites now require an `OTel.TracerProvider` argument instead of a
  `Tracer`. Wrapped each call with `OTelCore.getTracerTracerProvider
  tracer` and added a qualified import of `OpenTelemetry.Trace.Core` as
  `OTelCore` (the `getTracerTracerProvider` accessor is exported from
  `Core`, not from the SDK's `OpenTelemetry.Trace`). See Surprises &
  Discoveries. *(Done 2026-04-23.)*
- [x] M2.7 — Run `cabal build all` and confirm it succeeds with zero
  deprecation warnings about `PgmqError` / `PgmqPoolError`. Build is
  green; `cabal build all 2>&1 | grep -iE 'deprecated|warning'` returns
  no output. *(Done 2026-04-23.)*
- [x] M3.1 — Run `cabal test shibuya-pgmq-adapter-test` and record pass
  counts. **Result: `112 examples, 0 failures` in 29.19s.** The plan
  predicted 86 — actual is higher, presumably because tests have been
  added since the plan was authored (see git log around
  `78620b7 test(telemetry): assert conventions-compliant attribute names`).
  No test was edited; all pass cleanly under the new dependency set.
  *(Done 2026-04-23.)*
- [x] M3.2 — Start a local PostgreSQL in the devShell (`pg_ctl start -l
  $PGHOST/postgres.log`) and Jaeger (`~/.local/bin/jaeger >
  /tmp/jaeger.log 2>&1 &`). Seed the example queues via the simulator
  and then run the consumer for ~10 seconds with `OTEL_TRACING_ENABLED=true`
  and `OTEL_SERVICE_NAME=shibuya-consumer`. *(Done 2026-04-23.)*
  *(Two environment caveats — see Surprises & Discoveries: the
  postgresql.conf pinned by `$PGDATA` does not set
  `unix_socket_directories`, so PG defaults to `/tmp` and we connected
  via `DATABASE_URL=postgresql://%2Ftmp/<dbname>` rather than the
  CLAUDE.md-documented `$PWD/db` socket; and the existing `shibuya`
  database has a stale `schema_migrations.checksum` column type, so we
  used a fresh `shibuya_pgmq_verify` database created via `psql -h /tmp
  -d postgres -c "CREATE DATABASE shibuya_pgmq_verify"`.)*
- [x] M3.3 — Query the Jaeger HTTP API and confirm v1.24 conformance:
  - Spans visible under `service=shibuya-consumer`:
    `"receive orders"`, `"receive payments"`, `"receive notifications"`,
    `"pgmq.delete orders"`, `"pgmq.set_vt orders"`, `"orders process"`.
  - Every messaging span carries: `db.system = "postgresql"`,
    `db.operation = "pgmq.read"`, `messaging.system = "pgmq"`,
    `messaging.operation = "receive"`, `messaging.destination.name =
    "orders"`. No span uses the legacy
    `messaging.operation.type = "send"` form.
  - `pgmq.delete orders` and `pgmq.set_vt orders` (queue-lifecycle
    operations) carry `span.kind = "internal"`. `receive orders`
    carries `span.kind = "consumer"`. Matches the plan's "Queue
    management spans report `SpanKind = Internal`" criterion.
  - The plan also called for a `"publish orders"` span — none was
    observed, *not* because the conventions are wrong, but because the
    simulator uses `runPgmq` (untraced) plus `sendMessageTraced` (which
    only injects W3C trace headers into the message). A `publish`
    span would only appear if the simulator switched to
    `runPgmqTraced`. That is a follow-up enhancement in the
    `shibuya-pgmq-example` simulator and is out of scope for this
    pgmq-version-bump plan.
  - Captured raw evidence in `/tmp/shibuya-jaeger-verify.json`
    (consumer side, ~11.7 KB) and
    `/tmp/shibuya-jaeger-verify-simulator.json` (simulator side,
    ~29.9 KB). *(Done 2026-04-23.)*
- [x] M4.1 — Bump the `version:` field in
  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` from `0.2.0.0` to
  `0.3.0.0`. The `shibuya-core ^>=0.2.0.0` and adapter-self-bound
  `shibuya-pgmq-adapter` bounds were left unchanged — the adapter
  consumes shibuya-core's API unchanged, and the adapter test-suite
  refers to the adapter library by name without a version constraint.
  *(Done 2026-04-23.)*
- [x] M4.2 — Prepend a `0.3.0.0 — 2026-04-23` section to
  `shibuya-pgmq-adapter/CHANGELOG.md` describing the pgmq-hs 0.2 upgrade
  and the user-visible impact on anyone monitoring pgmq spans. Also
  added a third Breaking Change entry covering the
  `sendMessageTraced` provider/tracer signature change discovered
  during M2 (see Surprises & Discoveries). *(Done 2026-04-23.)*
- [x] M4.3 — Run `nix fmt` and `nix flake check` and stage the final commit
  with `ExecPlan:` and `Intention:` trailers. `nix fmt` reported "0
  changed" (nothing to format); `nix flake check` reported
  `pre-commit-check` and `formatting` both green. Committed as
  `fd33704 chore(pgmq-adapter)!: upgrade to pgmq-hs 0.2.0.0`.
  *(Done 2026-04-23.)*
- [x] M5 — *(Follow-up after the main commit.)* Switch
  `shibuya-pgmq-example/app/Simulator.hs` to use `runPgmqTraced` instead
  of `runPgmq`, so the producer side actually emits the v1.24
  `publish orders` / `publish payments` / `publish notifications` spans
  (the earlier M3.3 verification only saw consumer-side `receive` spans
  because the simulator was using the untraced interpreter). Confirmed
  via Jaeger: a single trace now spans `pgmq.produce` (manual outer
  producer span on the simulator) → `publish payments` (auto-traced,
  v1.24 attributes) → `payments process` (Shibuya consumer-side span)
  → `pgmq.delete payments` (auto-traced, kind=internal). The trace
  context propagates correctly because the manual `pgmq.produce` span
  provides the OTel context that `sendMessageTraced` reads and
  injects into the message headers. *(Done 2026-04-24.)*


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`cabal.project.freeze` pins an `index-state`, not just per-package versions.**
  The freeze file's tail line `index-state: hackage.haskell.org
  2026-02-24T02:38:45Z` capped Hackage at a date before pgmq-hs 0.2.0.0
  was published. Bumping only the four `any.pgmq-* ==0.2.0.0` lines was
  not enough — the solver still rejected `pgmq-hasql 0.2.0.0` because the
  index-state pin made it invisible. Fix: ran `cabal update` (refreshed
  to `2026-04-24T03:15:26Z`) and bumped the `index-state:` line in the
  freeze file to match. Add this to the Plan of Work as an implicit step
  whenever bumping any pinned dep across a Hackage publish boundary.

- **First compilation failure under the bumped freeze file matches the
  plan's prediction exactly.** `cabal build all` failed at
  `app/Simulator.hs:229` with:

      app/Simulator.hs:229:83: error: [GHC-64725]
        • There is no handler for 'Effectful.Error.Static.Error
                                     Pgmq.Effectful.Interpreter.PgmqRuntimeError' in the context

  Confirms the only blocker is the call-site rename catalogued in M2,
  and that no public adapter API needs adjustment — the
  `shibuya-pgmq-adapter` library compiled cleanly before the failure.

- **Plan's M2 file list was incomplete: a seventh `PgmqError` call site
  exists in `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs`.**
  `rg -n 'PgmqError\b' shibuya-pgmq-adapter shibuya-pgmq-adapter-bench
  shibuya-pgmq-example` after applying the six listed edits returned
  two extra hits in `ChaosSpec.hs` (an import line and the
  `runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a ->
  IO a` annotation — same shape as `IntegrationSpec.hs`). Likely a
  duplicate copied from `IntegrationSpec.hs`. Fix is mechanical (same
  rename); recorded as M2.6a above. *Lesson:* when the plan enumerates
  call sites for a rename, also run the grep up front, not just at the
  end — the enumeration was authored from a stale snapshot.

- **Local PG was not configured to listen on `$PGHOST/db` — fell back to
  `/tmp` socket.** The CLAUDE.md says the devShell sets `PGHOST=$PWD/db`
  and the project connects over a Unix socket in that directory. In
  practice the existing `$PGDATA/postgresql.conf` does not set
  `unix_socket_directories`, so PG starts with the default and listens
  at `/tmp/.s.PGSQL.5432`. Both inside and outside `nix develop --command`
  this is the same. For the M3.2 verification we connected with
  `DATABASE_URL=postgresql://%2Ftmp/<dbname>` (URL-encoded `/tmp`).
  This is an environment hygiene issue, not a regression caused by the
  upgrade — recording so a future contributor running M3 from a clean
  checkout knows the doc-prescribed `DATABASE_URL` may need adjusting.

- **The existing `shibuya` database has a stale
  `schema_migrations.checksum` column type incompatible with current
  pgmq-migration.** Running the simulator against it fails with:

      SessionUsageError (StatementSessionError 1 0
        "select checksum from schema_migrations where filename = $1 limit 1"
        ["\"pgmq_v1.11.0\""] False
        (UnexpectedColumnTypeStatementError 0 25 1043))

  Postgres OID 1043 is `varchar`, OID 25 is `text`. The DB was likely
  bootstrapped months ago with a different `schema_migrations` shape,
  and current pgmq-migration expects `text`. We worked around this by
  creating a fresh `shibuya_pgmq_verify` database for the M3.2 telemetry
  run; the original `shibuya` database was left untouched. Repairing
  `shibuya` is a separate house-keeping task and out of scope for this
  pgmq-version-bump plan.

- **A second pgmq-effectful 0.2 break that the plan did not anticipate:
  `sendMessageTraced` now takes a `TracerProvider`, not a `Tracer`.**
  After the M2 renames the `shibuya-pgmq-simulator` executable still
  failed to build:

      app/Simulator.hs:230:34: error: [GHC-83865]
        • Couldn't match expected type 'OTel.TracerProvider'
                      with actual type 'OTel.Tracer'
        • In the first argument of 'sendMessageTraced', namely 'tracer'

  The new pgmq-effectful 0.2 signature
  (`pgmq-effectful/src/Pgmq/Effectful/Traced.hs:70`) is

      sendMessageTraced ::
        (Pgmq :> es, IOE :> es) =>
        OTel.TracerProvider ->
        QueueName ->
        MessageBody ->
        Maybe Value ->
        Eff es MessageId

  This change rides along with the OTel v1.24 rework: trace context is
  now injected by the propagator configured on the *provider* rather
  than carried implicitly via the tracer. The plan's "What changed in
  pgmq-hs 0.2.0.0" section item (4) calls out the propagator change
  for `injectTraceContext` / `extractTraceContext` but does not mention
  that `sendMessageTraced` likewise switched to taking a provider, so
  callers using the high-level helper are affected too — not just the
  low-level propagation helpers. Minimal fix at the two call sites:
  derive the provider from the existing `Tracer` value with
  `OpenTelemetry.Trace.Core.getTracerTracerProvider`. The accessor is
  exported from `OpenTelemetry.Trace.Core`, not from the SDK's
  `OpenTelemetry.Trace`, so the simulator gained a qualified import of
  `OpenTelemetry.Trace.Core` as `OTelCore`. Threading a separate
  provider value through `Example.Telemetry.withTracing` was considered
  but rejected as overscope for this version-bump — the local accessor
  lookup is one extra function call per send and reads the same value
  the SDK already keeps inside the `Tracer` record.


## Decision Log

Record every decision made while working on the plan.

- Decision: Migrate error-type names now rather than riding the one-release
  deprecation window.
  Rationale: The deprecated `PgmqError` in pgmq-effectful 0.2 is a
  `newtype PgmqError = PgmqPoolError UsageError`, a *different* Haskell type
  from `PgmqRuntimeError`. `runPgmq` / `runPgmqTraced` in 0.2 now require
  `Error PgmqRuntimeError :> es`, so code that spells `runErrorNoCallStack
  @PgmqError` will fail to typecheck rather than just produce a deprecation
  warning. There is no way to stay on the old name through the next
  release; the rename is what unlocks compilation.
  Date: 2026-04-23

- Decision: Keep Shibuya's own `extractTraceHeaders` in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` instead of
  switching to the new `Pgmq.Effectful.Telemetry.extractTraceContext`
  helper that ships in pgmq-effectful 0.2.
  Rationale: Shibuya's adapter converts pgmq message headers into
  `Shibuya.Core.Types.TraceHeaders`, which is `[(ByteString, ByteString)]`
  — a type that lives in `shibuya-core` and feeds into Shibuya's
  own `Shibuya.Telemetry.Propagation.extractTraceContext`. The new
  pgmq-effectful helper instead emits `Network.HTTP.Types.RequestHeaders`
  (`[(CI ByteString, ByteString)]`) and requires a `TracerProvider` to
  apply the configured propagator. Adopting it would force churn in
  `shibuya-core`'s `TraceHeaders` type definition and in every adapter
  (not just pgmq) that populates `Envelope.traceContext`. That is out of
  scope for this pgmq-version bump; the adapter's existing header
  extraction still works because pgmq's on-the-wire representation — a
  JSON object in the `headers` column — has not changed.
  Date: 2026-04-23

- Decision: Bump `shibuya-pgmq-adapter` version to `0.3.0.0` rather than
  `0.2.1.0`.
  Rationale: Although the adapter's public API is unchanged, the
  underlying pgmq trace schema has shifted in a way that is observable
  to any external system (Jaeger, Grafana, Tempo, Datadog, honeycomb)
  that queries on the old span names or attribute keys. Following
  semantic versioning's spirit, changes to the observable telemetry
  output warrant a major bump so downstream dashboard owners notice.
  Date: 2026-04-23

- Decision: Do not adopt `pgmq-config` (the new declarative queue DSL
  introduced in pgmq-hs 0.1.3.0) as part of this upgrade.
  Rationale: Scope — `pgmq-config` is additive and would replace the
  imperative `createQueue` calls in `shibuya-pgmq-example` with a
  declarative topology record. That is a reasonable follow-up but not
  required to get off 0.1.x, and bundling it into this plan would mix
  "correctness of version bump" work with "API-ergonomics improvement"
  work. A separate ExecPlan can pick it up.
  Date: 2026-04-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### What was achieved

The repository's pgmq-hs dependency (`pgmq-core`, `pgmq-hasql`,
`pgmq-effectful`, `pgmq-migration`) is now pinned to `0.2.0.0` from
Hackage. All seven `PgmqError` call sites in the test, bench, and
example trees were renamed to `PgmqRuntimeError`. `cabal build all`
completes with zero deprecation warnings. The adapter test suite
passes 112 of 112 examples in 29.19s. The traced interpreter is
emitting v1.24-conformant spans observable in Jaeger
(`receive orders` rather than `pgmq read`; `messaging.operation` rather
than `messaging.operation.type`; `SpanKind.Internal` for queue
lifecycle ops; `SpanKind.Consumer` for read ops).

The adapter version was bumped from `0.2.0.0` to `0.3.0.0` to signal
the observable telemetry-schema change to downstream dashboard owners
(see Decision Log entry from 2026-04-23 for rationale).

### Original purpose vs. the result

The plan's stated demonstrable outcomes were:

1.  `cabal build all` succeeds with no warnings about deprecated
    `PgmqError` / `PgmqPoolError`. — **Met.**
2.  `cabal test shibuya-pgmq-adapter-test` passes (plan said
    86 tests; actual 112; no test count *decreased*). — **Met.**
3.  Jaeger traces show the new v1.24 names. — **Met. After M5
    follow-up, the simulator uses `runPgmqTraced` and emits
    `publish orders` / `publish payments` spans with
    `messaging.operation = "publish"`,
    `messaging.destination.name = <queue>`, and
    `db.operation = "pgmq.send"`. The consumer continues to emit
    `receive orders` / `pgmq.delete orders` / `pgmq.set_vt orders` as
    before. A single end-to-end trace now spans both services
    (e.g. `shibuya-simulator: publish payments → shibuya-consumer:
    payments process → pgmq.delete payments`).**
4.  `cabal.project.freeze` pins each pgmq package at `0.2.0.0`. — **Met.**

### Gaps / follow-ups

- ~~The example simulator in `shibuya-pgmq-example/app/Simulator.hs`
  still uses the untraced `runPgmq` interpreter…~~ **Resolved by M5.**
  Simulator was switched to `runPgmqTraced`. `publish orders` /
  `publish payments` spans now appear, and a single trace links
  producer and consumer across services.
- The `Example.Telemetry.withTracing` callback hands an `OTel.Tracer`
  to its action. The Simulator now has to thread
  `OTelCore.getTracerTracerProvider tracer` at every call site. A
  cleaner refactor would change `withTracing` to pass both the
  `Tracer` and the `TracerProvider` (or a small record). Deferred:
  out of scope for the version bump.
- The local `shibuya` PostgreSQL database has a stale
  `schema_migrations.checksum` column type that prevents
  pgmq-migration from running cleanly against it (see Surprises &
  Discoveries). Recreating that database is unrelated dev-environment
  hygiene; left as-is.
- Inside `nix develop`, `pg_ctl start` listens at `/tmp/.s.PGSQL.5432`
  rather than `$PGHOST/.s.PGSQL.5432` because `postgresql.conf` does
  not pin `unix_socket_directories`. The CLAUDE.md-documented
  `DATABASE_URL` form expects the latter. Worth either fixing the
  cluster's config or updating CLAUDE.md.

### Lessons

- **Always grep for the symbol about to be renamed before relying on
  the plan's enumeration of call sites.** The plan listed six
  `PgmqError` call sites; a seventh sat in `ChaosSpec.hs`, which was
  almost certainly added after the plan was authored. A 5-second `rg`
  at the top of M2 would have surfaced it.
- **A version bump that preserves a library's API surface can still
  break callers via a third party.** The adapter's own
  `Shibuya.Adapter.Pgmq*` modules were untouched, but the example's
  `sendMessageTraced` call sites broke because the *upstream helper's*
  signature changed (`Tracer` → `TracerProvider`) — a change ridden
  along with pgmq-effectful's switch to a propagator-aware
  TracerProvider model. This is the kind of break that "no public API
  change in the adapter" doesn't catch, and is good evidence for the
  decision to bump the adapter to 0.3.0.0 rather than 0.2.1.0.
- **`cabal.project.freeze` carries an `index-state:` line that's just as
  load-bearing as the per-package pins.** Bumping `any.pkg ==X` lines
  without bumping `index-state:` (when the new version was published
  after the existing pin's date) silently leaves the solver looking at
  a stale Hackage index. A future "bump dependency" plan should
  spell out the `cabal update` + `index-state:` bump as an explicit
  step, not leave it implicit.


## Context and Orientation

### What Shibuya is

Shibuya (repo root: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`)
is a supervised queue-processing framework for Haskell, inspired by
Elixir's Broadway. It is published to Hackage under `shibuya-core`
0.2.0.0. The library's entry point is `runApp` in
`shibuya-core/src/Shibuya/App.hs`, which accepts a list of
`QueueProcessor` records, each pairing an `Adapter` (the queue-source
abstraction) with a `Handler` (the pure message-handling function).

### What the pgmq adapter is

The `shibuya-pgmq-adapter` package (path:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter`)
implements `Adapter` over PGMQ, the PostgreSQL-backed queue extension.
Its public module surface is:

- `Shibuya.Adapter.Pgmq` — the `pgmqAdapter` constructor and a handful
  of topic-management helpers. Defined in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`.
- `Shibuya.Adapter.Pgmq.Config` — the `PgmqAdapterConfig` record and
  its knobs (polling, DLQ, FIFO, prefetch). Defined in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`.
- `Shibuya.Adapter.Pgmq.Convert` — conversions between pgmq types and
  Shibuya `Envelope`, plus `extractTraceHeaders` for pulling W3C
  tracing headers out of a pgmq message's JSON headers column.
  Defined in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`.
- `Shibuya.Adapter.Pgmq.Internal` — the streaming source and ack
  handler implementation. Defined in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`.

None of these files exposes or re-exports the
`Pgmq.Effectful.PgmqError` name; the name leaks only into tests,
benchmarks, and the example application.

### What pgmq-hs is

pgmq-hs lives at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (the
authoritative path on this workstation). It is a multi-package project:

- `pgmq-core` — value types (`Message`, `MessageId`, `Queue`,
  `QueueName`, the new `TopicBinding`, etc.).
- `pgmq-hasql` — hasql-backed SQL sessions (low-level, no effect
  system).
- `pgmq-effectful` — the `Pgmq` effect for the
  [effectful](https://hackage.haskell.org/package/effectful) effect
  system. Exposes two interpreters: `runPgmq` (no tracing) and
  `runPgmqTraced` (wraps every op in an OpenTelemetry span).
- `pgmq-migration` — bundles the upstream pgmq SQL so the schema
  can be installed in any Postgres database without requiring the
  pgmq extension.
- `pgmq-config` — a declarative queue topology DSL (new in 0.1.3.0;
  not used by shibuya today and out of scope for this plan).

shibuya-pgmq-adapter depends on `pgmq-core`, `pgmq-effectful`, and
`pgmq-hasql` for the library code, and additionally on `pgmq-migration`
for the test suite. The bench and example packages pull the same set.

### What changed in pgmq-hs 0.2.0.0

The authoritative source is the pgmq-hs CHANGELOG at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/CHANGELOG.md`.
The breaking changes that matter here, paraphrased:

1.  `Pgmq.Effectful.Interpreter` now exports `PgmqRuntimeError`, an
    algebraic type with three constructors:

        data PgmqRuntimeError
          = PgmqAcquisitionTimeout
          | PgmqConnectionError HasqlErrors.ConnectionError
          | PgmqSessionError    HasqlErrors.SessionError

    A new helper `fromUsageError :: UsageError -> PgmqRuntimeError`
    converts from the hasql-pool error type, and `isTransient ::
    PgmqRuntimeError -> Bool` classifies errors for retry logic.

    The old `newtype PgmqError = PgmqPoolError UsageError` is kept for
    one release with a `{-# DEPRECATED #-}` pragma but is no longer the
    error type carried by `runPgmq`.

2.  `runPgmq`, `runPgmqTraced`, and `runPgmqTracedWith` now require an
    `Error PgmqRuntimeError :> es` effect in the stack. For callers
    that previously wrote `runErrorNoCallStack @PgmqError . runPgmq`,
    the fix is one token: change the type application to
    `@PgmqRuntimeError`.

3.  The traced interpreter in
    `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Interpreter/Traced.hs`
    now follows OpenTelemetry semantic-conventions v1.24. For every
    pgmq operation it emits `db.system = "postgresql"` and
    `db.operation = "pgmq.<fn>"`. For messaging ops (send, read, pop,
    topic send) it additionally emits `messaging.system = "pgmq"`,
    `messaging.destination.name = <queue-or-routing-key>`, and
    `messaging.operation` ∈ `{"publish", "receive"}`. Span names take
    the form `"<operation> <destination>"` for messaging spans (e.g.
    `"publish orders"`) and `"<db.operation> <destination>"` for
    lifecycle and observability spans. Queue-management ops now carry
    `SpanKind.Internal`; send variants carry `SpanKind.Producer`; read
    and pop variants carry `SpanKind.Consumer`.

4.  Trace-context propagation helpers (`injectTraceContext`,
    `extractTraceContext`) now take a `TracerProvider` so the
    propagator configured on the provider is used (W3C by default, B3
    / Datadog / custom all supported). The on-wire carrier type
    `TraceHeaders` is now `Network.HTTP.Types.RequestHeaders`
    (`[(CI ByteString, ByteString)]`) instead of a pgmq-defined alias.
    This does not touch shibuya-pgmq-adapter — the adapter never
    calls those helpers; it extracts W3C trace headers directly from
    the JSON headers column via its own `extractTraceHeaders` in
    `Shibuya.Adapter.Pgmq.Convert`.

5.  `pgmq-config`'s `ensureQueues` was made idempotent (bug fix, not
    breaking).  Shibuya does not use `pgmq-config`; the fix is
    irrelevant here but noted for completeness.

The adapter itself uses `sendMessage`, `sendMessageWithHeaders`,
`sendTopic`, `sendTopicWithHeaders`, `readMessage`, `readWithPoll`,
`readGrouped`, `readGroupedWithPoll`, `readGroupedRoundRobin`,
`readGroupedRoundRobinWithPoll`, `deleteMessage`, `archiveMessage`, and
`changeVisibilityTimeout`. All of these continue to exist with the same
argument and return types in 0.2 — only the surrounding error type
changes.

### Term glossary

- **PGMQ**: PostgreSQL Message Queue, a queue system that stores messages
  in Postgres tables. The shibuya-pgmq-adapter is a client that reads
  from and writes to these tables through pgmq-hs.
- **pgmq-hs**: the Haskell client library for PGMQ. It is split into
  five packages (`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`,
  `pgmq-migration`, `pgmq-config`). All share a single version number
  and release together.
- **effectful**: a Haskell effect system. In this codebase effects
  appear as typeclass constraints like `(Pgmq :> es, IOE :> es)` and
  an effect computation has type `Eff es a`.
- **visibility timeout**: the pgmq feature that makes a just-read
  message invisible to other readers for a configurable number of
  seconds, giving the consumer time to process it before the message
  becomes re-deliverable.
- **OpenTelemetry semantic conventions**: a spec that says "if you are
  tracing a messaging operation, the attribute for the queue name
  should be `messaging.destination.name`, not `queue.name` or
  `messaging.queue`." pgmq-effectful 0.2 is compliant with v1.24;
  pgmq-effectful 0.1 was not.
- **`PgmqError` vs. `PgmqRuntimeError`**: the old opaque vs. new
  structured error type. See Decision Log for why we migrate rather
  than ride the deprecation.
- **cabal freeze file**: `cabal.project.freeze` at the repo root;
  records the exact version cabal solved for each dependency. Must be
  updated in lock-step with version-bound bumps, otherwise cabal
  will keep resolving to the pinned old version.


## Plan of Work

The work is four milestones. Each milestone leaves the tree in a
compilable-and-committable state.

### Milestone 1 — Version-bound bump

At the end of this milestone, every `pgmq-*` build dependency in the
project declares `^>=0.2` and the freeze file pins `==0.2.0.0`. The
build will *not* succeed yet — the M1.5 step documents the expected
failure. That failure is what M2 addresses.

The files to edit are all `.cabal` files that mention `pgmq-`:

1.  `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` — the library
    stanza currently reads, at lines ~31–47:

        build-depends:
          ...
          pgmq-core ^>=0.1,
          pgmq-effectful ^>=0.1,
          pgmq-hasql ^>=0.1,
          ...

    Change each `^>=0.1` to `^>=0.2`. The test-suite stanza a few
    lines below pulls these unbounded plus `pgmq-migration`; leave
    the unbounded ones alone (they inherit from the library) and add
    an explicit `^>=0.2` on the `pgmq-migration` line so the test
    suite is pinned to the same major series as the library.

2.  `shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal` —
    both the `benchmark shibuya-pgmq-adapter-bench` stanza (lines
    ~54–73) and the `executable endurance-test` stanza (lines
    ~97–114) list `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and
    `pgmq-migration` without version bounds. Add `^>=0.2` to each of
    those four in each stanza.

3.  `shibuya-pgmq-example/shibuya-pgmq-example.cabal` — the `library`
    stanza (lines ~39–51), the `executable shibuya-pgmq-simulator`
    stanza (lines ~56–69), and the `executable shibuya-pgmq-consumer`
    stanza (lines ~73–90) all list `pgmq-core`, `pgmq-effectful`,
    `pgmq-hasql`, or `pgmq-migration` without version bounds. Add
    `^>=0.2` in each.

4.  `cabal.project.freeze` — four lines currently read

        any.pgmq-core ==0.1.1.0,
        any.pgmq-effectful ==0.1.1.0,
        any.pgmq-hasql ==0.1.1.0,
        any.pgmq-migration ==0.1.1.0,

    Change the three `==0.1.1.0` / `==0.1.0.0` right-hand sides to
    `==0.2.0.0`. The freeze file is a snapshot of the last successful
    solve; updating it by hand is the standard workaround for bumping
    a pinned package without rerunning `cabal freeze` from scratch.

No `source-repository-package` stanzas are needed — pgmq-hs 0.2.0.0 is
published to Hackage. Confirm this before editing by running

    cabal v2-info pgmq-effectful-0.2.0.0

and, if the Hackage publish lags, fall back to a
`source-repository-package` pointing at
`github.com/shinzui/pgmq-hs` at the 0.2.0.0 tag. Record that choice in
the Decision Log if it comes up.

### Milestone 2 — Error-type rename at call sites

At the end of this milestone, every use of `Pgmq.Effectful.PgmqError`
has been replaced with `Pgmq.Effectful.PgmqRuntimeError`. The grep

    rg -n 'PgmqError\b' shibuya-*

should print zero lines. After each file edit, attempt a
`cabal build <package>` on the package containing the edited file
before moving to the next file; this catches import-list typos
immediately.

The six files and their specific edits:

1.  `shibuya-pgmq-adapter/test/TestUtils.hs` — at line 23 replace
    `import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)` with
    `import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)`.
    At line 33 the signature

        runWithPool :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO a

    becomes

        runWithPool :: Pool.Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO a

    The comment at line 32 ("This handles the Error PgmqError effect")
    should be updated to reflect the new type name.

2.  `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs` —
    at line 21 replace
    `import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)` with
    `import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)`.
    At line 65 the signature

        runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO a

    becomes

        runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO a

3.  `shibuya-pgmq-adapter-bench/bench/Bench/Raw.hs` — at line 19
    replace
    `import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)` with
    `import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)`.
    At line 124

        runEffectful :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO ()

    becomes

        runEffectful :: Pool.Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO ()

    At lines 126 and 145,

        runEff . runErrorNoCallStack @PgmqError . runPgmq pool $ ...

    becomes

        runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $ ...

4.  `shibuya-pgmq-adapter-bench/app/Endurance.hs` — at line 40
    replace
    `import Pgmq.Effectful.Interpreter (PgmqError)` with
    `import Pgmq.Effectful.Interpreter (PgmqRuntimeError)`.
    At line 326,

        runEff $ runErrorNoCallStack @PgmqError $ runPgmq pool $ ...

    becomes

        runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq pool $ ...

5.  `shibuya-pgmq-example/app/Simulator.hs` — at line 44
    replace
    `import Pgmq.Effectful (PgmqError, runPgmq)` with
    `import Pgmq.Effectful (PgmqRuntimeError, runPgmq)`.
    At lines 229 and 262 the explicit type annotation

        result :: Either PgmqError () <- ...

    becomes

        result :: Either PgmqRuntimeError () <- ...

6.  `shibuya-pgmq-example/app/Consumer.hs` — at line 41
    replace
    `import Pgmq.Effectful.Interpreter (PgmqError)` with
    `import Pgmq.Effectful.Interpreter (PgmqRuntimeError)`.
    At line 249,

        runEff $ runErrorNoCallStack @PgmqError $ runPgmqTraced pool tracer $ ...

    becomes

        runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmqTraced pool tracer $ ...

When all six edits are in place, `cabal build all` at the repo root
must complete cleanly. If it reports deprecation warnings for
`PgmqError` / `PgmqPoolError` the rename has been missed somewhere —
re-run `rg -n 'PgmqError\b' .`.

### Milestone 3 — Test and telemetry verification

The test suite (the HSpec-based
`shibuya-pgmq-adapter-test`) continues to compile and run against the
new dependency set; the example application still emits traces that
now match v1.24 conventions.

The unit-level proof is

    cabal test shibuya-pgmq-adapter-test

at the repo root. It spins up a tmp-postgres instance, installs the
pgmq schema via `pgmq-migration`, and runs both pure and integration
specs. Expect the same pass count as before the upgrade; record the
actual counts in Outcomes & Retrospective.

The end-to-end telemetry proof is the one a dashboard owner actually
cares about: do the spans look right? Run the following from the repo
root (the commands assume the devShell has been entered; the CLAUDE.md
at repo root documents the environment setup):

    pg_ctl start -l $PGHOST/postgres.log
    ~/.local/bin/jaeger > /tmp/jaeger.log 2>&1 &

    # In one terminal — seed the queues and send messages:
    OTEL_TRACING_ENABLED=true \
      OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318" \
      OTEL_SERVICE_NAME="shibuya-simulator" \
      cabal run shibuya-pgmq-simulator

    # In another terminal — consume them:
    OTEL_TRACING_ENABLED=true \
      OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318" \
      OTEL_SERVICE_NAME="shibuya-consumer" \
      cabal run shibuya-pgmq-consumer

Let both run for about ten seconds, then Ctrl-C the consumer. Query
Jaeger:

    curl -s "http://127.0.0.1:16686/api/traces?service=shibuya-consumer&limit=5" \
      | jq '.data[0].spans[] | {operationName, tags: [.tags[] | select(.key | startswith("messaging") or startswith("db"))]}'

Expected (abridged):

    {
      "operationName": "receive orders",
      "tags": [
        {"key": "db.system",                    "value": "postgresql"},
        {"key": "db.operation",                 "value": "pgmq.read"},
        {"key": "messaging.system",             "value": "pgmq"},
        {"key": "messaging.operation",          "value": "receive"},
        {"key": "messaging.destination.name",   "value": "orders"}
      ]
    }

Any span whose `operationName` begins with `"pgmq "` (old style) or
whose tag set contains `messaging.operation.type` (old attribute
key) is a signal that a stale dependency is being loaded. Diagnose by
checking `cabal build --dry-run` to see which `pgmq-effectful`
version is being resolved.

Record the captured output in Outcomes & Retrospective as the
observable proof that the plan's purpose is met.

### Milestone 4 — Version, changelog, and formatting

At the end of this milestone the change is ready to commit.

1.  Bump `shibuya-pgmq-adapter.cabal`'s `version:` line from
    `0.2.0.0` to `0.3.0.0`. See the Decision Log for why this is a
    major bump.

2.  Prepend the following section to
    `shibuya-pgmq-adapter/CHANGELOG.md`, above the existing
    `0.2.0.0 — 2026-04-22` section:

        ## 0.3.0.0 — 2026-04-23

        Upgraded to `pgmq-hs` 0.2.0.0 series
        (`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`
        all at `0.2.0.0`).

        ### Breaking Changes

        - Consumers that pin the `Pgmq.Effectful.PgmqError` name in
          their own `runError` / `runErrorNoCallStack` stack must
          migrate to `PgmqRuntimeError`. The old type is still
          re-exported as a deprecated alias for one release.
        - Spans emitted by the traced interpreter now follow
          OpenTelemetry semantic-conventions v1.24. Span names
          (`"publish my-queue"`, `"receive my-queue"`) and attribute
          keys (`messaging.operation`, `messaging.system`,
          `messaging.destination.name`) have changed. Dashboards and
          alerts keyed on the old names will need updating.

        ### Other Changes

        - No user-visible changes to `shibuya-pgmq-adapter`'s own API.

3.  Run `nix fmt` and stage everything. Create one commit with the
    trailers

        ExecPlan: docs/plans/3-upgrade-pgmq-hs-to-0.2.md
        Intention: intention_01kg953t69enps79pj77taz6nw


## Concrete Steps

This section must be updated as work proceeds. The exact commands to
run, with expected transcripts:

### Before anything

Confirm the current `pgmq-*` pins:

    grep -n 'pgmq-' cabal.project.freeze

Expected output:

    any.pgmq-core ==0.1.1.0,
    any.pgmq-effectful ==0.1.1.0,
    any.pgmq-hasql ==0.1.1.0,
    any.pgmq-migration ==0.1.1.0,

### Milestone 1

Apply the bumps described in Plan of Work § Milestone 1.

    cabal build all 2>&1 | tail -40

Expected output: a compile error in one of the six test/bench/example
files, citing something like

    Couldn't match type 'PgmqError' with 'PgmqRuntimeError'

or

    Not in scope: 'PgmqError'

Record the actual first failure in Surprises & Discoveries.

### Milestone 2

Apply the six renames described in Plan of Work § Milestone 2.

    rg -n 'PgmqError\b' shibuya-* docs

Expected output: zero lines. (The `docs/` include is defensive — the
name occasionally shows up in historical notes.)

    cabal build all 2>&1 | tail -20

Expected output:

    Linking ... shibuya-pgmq-example ...
    Linking ... shibuya-pgmq-adapter-bench ...
    ... (no warnings)

### Milestone 3

    cabal test shibuya-pgmq-adapter-test 2>&1 | tail -20

Expected output ends with a "Finished in ..." line and an `OK` status.
Record the example count.

Then run the telemetry verification (§ Milestone 3 above). Save the
`curl` output to `/tmp/shibuya-jaeger-verify.json` and paste the key
tags into Outcomes & Retrospective.

### Milestone 4

    # Edit shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal (version bump)
    # Edit shibuya-pgmq-adapter/CHANGELOG.md (prepend 0.3.0.0 section)

    nix fmt
    nix flake check

    git add shibuya-pgmq-adapter shibuya-pgmq-adapter-bench shibuya-pgmq-example cabal.project.freeze
    git commit -m "$(cat <<'EOF'
    chore(pgmq-adapter): upgrade to pgmq-hs 0.2.0.0

    Bumps pgmq-core, pgmq-hasql, pgmq-effectful, and pgmq-migration
    to the 0.2.0.0 series; migrates PgmqError to the new structured
    PgmqRuntimeError type at all call sites; bumps
    shibuya-pgmq-adapter to 0.3.0.0 to signal the change in emitted
    OpenTelemetry attribute keys and span names (now compliant with
    semantic-conventions v1.24).

    ExecPlan: docs/plans/3-upgrade-pgmq-hs-to-0.2.md
    Intention: intention_01kg953t69enps79pj77taz6nw
    EOF
    )"


## Validation and Acceptance

Acceptance is observable, not internal:

1.  `cabal build all` at the repo root succeeds with zero warnings
    about deprecated `PgmqError` / `PgmqPoolError`.

2.  `cabal test shibuya-pgmq-adapter-test` reports the same number of
    passing examples as before the upgrade. (Record the current number
    in Outcomes & Retrospective during M3.1.)

3.  With PostgreSQL and Jaeger running locally and the simulator +
    consumer executed as shown in Plan of Work § Milestone 3, a
    `curl` against the Jaeger API returns at least one span whose
    `operationName` starts with `publish ` or `receive ` and whose
    tags include `messaging.operation` with value `"publish"` /
    `"receive"` (not the old `messaging.operation.type`).

4.  `grep -n '^version:' shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`
    prints `version: 0.3.0.0`.

5.  `head -4 shibuya-pgmq-adapter/CHANGELOG.md` prints

        # Changelog

        ## 0.3.0.0 — 2026-04-23

If any of steps 1–3 fails, the plan is not complete. Steps 4 and 5 are
mechanical and can be verified independently.


## Idempotence and Recovery

Every edit in this plan is local, reversible, and additive-or-renaming.
A `git stash` / `git reset --hard` at any point restores the pre-plan
tree. No migrations are performed against real databases; the
integration tests use tmp-postgres instances that are torn down at
end-of-test.

If M1.5 reveals that pgmq-hs 0.2.0.0 is not yet published to Hackage
at the time the plan is run, fall back to `source-repository-package`
stanzas in `cabal.project`. The template is:

    source-repository-package
      type: git
      location: https://github.com/shinzui/pgmq-hs
      tag: <commit-sha-of-0.2.0.0-release>
      subdir: pgmq-core

    source-repository-package
      type: git
      location: https://github.com/shinzui/pgmq-hs
      tag: <same-commit-sha>
      subdir: pgmq-hasql

    -- (repeat for pgmq-effectful and pgmq-migration)

Record the commit SHA chosen in the Decision Log so a future
implementer can reproduce the solve.

If `nix flake check` fails on Fourmolu formatting after the edits,
accept Fourmolu's output as authoritative — see the repo's
`fourmolu.yaml` for the style and the existing
`docs/plans/1-provide-nfdata-for-core-types.md` for precedent.

If a pre-commit hook rejects the commit, fix the root cause (usually a
missed `nix fmt` run) and re-stage — do not use `--no-verify` and do
not `git commit --amend`, because the hook aborts before the commit
is created.


## Interfaces and Dependencies

### Upstream packages and exact versions

At the end of Milestone 1 the project pins:

- `pgmq-core ==0.2.0.0` (Hackage)
- `pgmq-hasql ==0.2.0.0` (Hackage)
- `pgmq-effectful ==0.2.0.0` (Hackage)
- `pgmq-migration ==0.2.0.0` (Hackage)

### Error-type surface after the upgrade

In `pgmq-effectful` 0.2.0.0 the error type exported for the
`runPgmq` family is:

    module Pgmq.Effectful.Interpreter where

    data PgmqRuntimeError
      = PgmqAcquisitionTimeout
      | PgmqConnectionError Hasql.Errors.ConnectionError
      | PgmqSessionError    Hasql.Errors.SessionError
      deriving stock (Show, Eq, Generic)

    instance Exception PgmqRuntimeError

    fromUsageError :: Hasql.Pool.UsageError -> PgmqRuntimeError
    isTransient    :: PgmqRuntimeError -> Bool

The shibuya-pgmq-adapter library itself does **not** need to import
`PgmqRuntimeError` — its public API operates under the `Pgmq` effect
constraint and leaves error handling to the caller. Only the
adapter's test suite, the bench suite, and the example executables
need to name the type.

### `runPgmq` and `runPgmqTraced` signatures after the upgrade

    runPgmq ::
      (IOE :> es, Error PgmqRuntimeError :> es) =>
      Hasql.Pool.Pool ->
      Eff (Pgmq : es) a ->
      Eff es a

    runPgmqTraced ::
      (IOE :> es, Error PgmqRuntimeError :> es) =>
      Hasql.Pool.Pool ->
      OpenTelemetry.Trace.Core.Tracer ->
      Eff (Pgmq : es) a ->
      Eff es a

The callers in this repo already provide `IOE :> es` and an `Error`
slot; the upgrade is purely the type-level rename of the error
parameter.

### Span schema emitted by the traced interpreter after the upgrade

Every span emitted by `runPgmqTraced` carries:

- `db.system = "postgresql"` (Text)
- `db.operation = "pgmq.<fn>"` (Text, e.g. `"pgmq.send"`, `"pgmq.read"`,
  `"pgmq.archive"`, `"pgmq.set_vt"`)

Messaging spans (sends, reads, pops, topic sends) additionally carry:

- `messaging.system = "pgmq"` (Text)
- `messaging.operation` (Text, one of `"publish"` or `"receive"`)
- `messaging.destination.name` (Text, queue name or routing key)
- `messaging.message.id` (Text, when a single message id is known)
- `messaging.batch.message_count` (Int64, when a batch size is
  known)

Span names and kinds:

- `"publish <dest>"` with `SpanKind.Producer` — every send variant.
- `"receive <dest>"` with `SpanKind.Consumer` — every read/pop
  variant.
- `"pgmq.<fn> <dest>"` with `SpanKind.Internal` — queue management
  and per-message lifecycle ops (archive, delete, set_vt, bind_topic,
  …).
- `"pgmq.<fn>"` (no destination) with `SpanKind.Internal` — ops
  without a per-queue scope (`list_queues`, `metrics_all`, …).

The shibuya-pgmq-adapter library does not construct these spans; it
only causes them to happen by calling the effect. No adapter-side
changes are needed to keep the schema correct.
