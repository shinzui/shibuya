---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [getAppMetrics returns no processors after waitApp](1-getappmetrics-returns-no-processors-after-waitapp.md) - Shibuya.App.getAppMetrics reads the master's live registry, which drops finished processors, so a caller cannot read final counts through the public API after waitApp.
- [Benchmark time gate is unreadable under concurrent machine load](2-benchmark-time-gate-is-unreadable-under-concurrent-machine-load.md) - The shibuya-core-bench time gate (+RTS -N, --fail-if-slower 10) reported 15-48% regressions in unchanged code while other workloads loaded the machine, costing three extra comparison runs.
- [Benchmark time gate blocked again by concurrent machine load](3-benchmark-time-gate-blocked-again-by-concurrent-machine-load.md) - The shibuya-core-bench time gate for plans 56 and 60 could not be read because another session's load benchmark kept the load average at 24-44 on 36 cores, so both time comparisons were deferred to a quiet window.
- [cabal exec ghc rejects -package flags for in-tree dependencies](4-cabal-exec-ghc-rejects-package-flags-for-in-tree-dependencies.md) - Compiling a one-file diagnostic against the worktree's shibuya-core with cabal exec -- ghc failed while any project dependency was named with -package, costing several rebuild attempts.
- [PGMQ adapter dev PostgreSQL cluster no longer starts under the devShell](5-pgmq-adapter-dev-postgresql-cluster-no-longer-starts-under-the-devshell.md) - The shibuya-pgmq-adapter devShell now provides PostgreSQL 18 while its db/db cluster was initialised by an older major, so pg_ctl refuses it and the benchmark and example runs needed a throwaway cluster.
- [Kafka adapter private Redpanda broker cannot be started](6-kafka-adapter-private-redpanda-broker-cannot-be-started.md) - just redpanda-up (redpanda-local-up) and a direct container start of shibuya-kafka-adapter-rp-0 both hang with the container stopped, blocking the Kafka integration tests and the Jaeger check against a real broker.
- [Adapter benchmark time gate unreadable under concurrent machine load](7-adapter-benchmark-time-gate-unreadable-under-concurrent-machine-load.md) - The PGMQ adapter benchmark comparison ran at load average 15-27 on 36 cores from other sessions, so single runs disagreed on which cells were slower and the DB-backed bench timed out on 8-10 cells on both sides.
