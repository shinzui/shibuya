# Bundle Update Log

## 2026-11-13

* **Update**: FRIC-6 resolved: Resolved: broker starts, Kafka integration tests and trace check passed


* **Update**: FRIC-7 accepted: Accepted: the documented interleaved method resolved the gate for EP-5


* **Addition**: FRIC-7 records slowdown environment friction with mori://shinzui/shibuya-pgmq-adapter: Adapter benchmark time gate unreadable under concurrent machine load


* **Addition**: FRIC-6 records blocked environment friction with mori://shinzui/shibuya-kafka-adapter: Kafka adapter private Redpanda broker cannot be started


* **Addition**: FRIC-5 records detour environment friction with mori://shinzui/shibuya-pgmq-adapter: PGMQ adapter dev PostgreSQL cluster no longer starts under the devShell


* **Update**: FRIC-4 resolved: Resolved by documenting the working cabal exec recipe next to the stack-chunk diagnostic that needs it.


* **Addition**: FRIC-4 records slowdown tooling friction with mori://shinzui/shibuya: cabal exec ghc rejects -package flags for in-tree dependencies


* **Update**: FRIC-3 resolved: Resolved by documenting the interleaved confirming method that passed plans 56 and 60


* **Addition**: FRIC-3 records blocked environment friction with mori://shinzui/shibuya: Benchmark time gate blocked again by concurrent machine load


* **Update**: FRIC-2 resolved: Documented the load sensitivity in the bench README

* **Addition**: FRIC-2 records slowdown environment friction with mori://shinzui/shibuya: Benchmark time gate is unreadable under concurrent machine load

## 2026-11-12

* **Addition**: FRIC-1 records detour interface friction with mori://shinzui/shibuya: getAppMetrics returns no processors after waitApp

* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
