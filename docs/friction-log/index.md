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
