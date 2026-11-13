---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [getAppMetrics returns no processors after waitApp](1-getappmetrics-returns-no-processors-after-waitapp.md) - Shibuya.App.getAppMetrics reads the master's live registry, which drops finished processors, so a caller cannot read final counts through the public API after waitApp.
- [Benchmark time gate is unreadable under concurrent machine load](2-benchmark-time-gate-is-unreadable-under-concurrent-machine-load.md) - The shibuya-core-bench time gate (+RTS -N, --fail-if-slower 10) reported 15-48% regressions in unchanged code while other workloads loaded the machine, costing three extra comparison runs.
