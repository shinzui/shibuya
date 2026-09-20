# Shibuya

Supervised queue processing framework for Haskell, inspired by Broadway (Elixir):
unified queue abstraction, NQE-based supervision, backpressure, explicit ack semantics.

## Commands

```bash
cabal build all
cabal test shibuya-core            # both suites: shibuya-core-test, shibuya-core-gc-test
cabal run shibuya-example
nix fmt                            # treefmt (fourmolu); run before committing
nix flake check                    # formatting + flake checks
just --list                        # dev services, database recipes
```

The pre-commit hook runs treefmt and rejects unformatted commits. If it fails it
auto-formats — re-`git add` and commit again.

## Packages

| Package | Purpose |
|---|---|
| `shibuya-core` | The library. `Shibuya.App` (`runApp`, `QueueProcessor`) is the public entry point. |
| `shibuya-metrics` | Metrics sinks/exporters. |
| `shibuya-example` | Runnable multi-processor and batch examples. |
| `shibuya-core-bench` | Benchmarks plus `standalone-test` / `prod-stress` executables. |

Runner internals live under `Shibuya.Internal.Runner.*` (Master, Supervised,
Batcher, KeyedScheduler, …) — exposed but not part of the stable API. `Master`
is a handle around the shared NQE supervisor and metrics registry, not a
mailbox actor.

## Conventions

- GHC2024 plus per-package `default-extensions` — notably `NoFieldSelectors`,
  `OverloadedRecordDot` (`metrics.stats.processed`), and `OverloadedLabels`
  with generic-lens (`m & #state .~ new`). Check the cabal file before adding a
  `LANGUAGE` pragma.
- Always name a deriving strategy (`DerivingStrategies` is on).
- Effects are `effectful`: `(IOE :> es) => ... -> Eff es a`.
- Fourmolu, 2-space indent, trailing commas in import/export lists.
- Tests are HSpec + QuickCheck, mirroring source layout under `test/Shibuya/`.

## Docs

- `docs/architecture/` — message flow, core types, concurrency, metrics.
- `docs/USAGE_GUIDE.md`, `docs/HIGH_LEVEL_ARCHITECTURE.md`
- `docs/JAEGER_LOCAL_TESTING.md` — local OTLP/Jaeger setup for tracing.
- `docs/plans/`, `docs/masterplans/` — ExecPlans and master plans.

## Local environment

The nix devShell provisions PostgreSQL over a Unix socket (no TCP) and exports
`PGHOST=$PWD/db`, `PGDATA`, `PGDATABASE=shibuya`, and `PG_CONNECTION_STRING`.
Start it with `pg_ctl start -l $PGLOG`; `just create-database` / `just reset-database`
manage the database.
