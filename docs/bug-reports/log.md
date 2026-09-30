# Bundle Update Log

## 2026-09-30

* **Modification**: Reviewed the status metadata of all eleven reports against their cited sealed results in `mori://shinzui/keiro-runtime-kenshou`, later local runs, and that project's `docs/reports/2026-09-29-runtime-baseline.md` (artifact-level URI pending). BUG-2 through BUG-11 retain `fixed` with `fixedVersion: 0.10.0.0`: every cited published-release control passes, while historical 0.9.0.3 reproductions fail. BUG-1 retains `reported`: published 0.10.0.0 and pinned-head runs reproduce active handlers and late finalization, and no owning-repository reproduction is recorded to justify `confirmed`. Added review provenance to each report. This audit reads existing evidence; it does not claim new scenario executions.

## 2026-09-27

* **Addition**: BUG-11 records that unsubscribe-after-subscribe-all still delivered excluded processor updates on metrics 0.9.0.3; Hackage 0.10.0.0 passes.
* **Addition**: BUG-10 records that metrics 0.9.0.3 accepted WebSocket upgrades with the endpoint disabled; Hackage 0.10.0.0 passes.
* **Addition**: BUG-9 records leaked WebSocket connection slots under disconnect and setup faults on metrics 0.9.0.3; Hackage 0.10.0.0 passes.
* **Addition**: BUG-8 records historical false-ready and false-live health responses after a required processor fails or the master stops; Hackage 0.10.0.0 controls pass.
* **Addition**: BUG-7 records stale activity timestamps making healthy processing look stuck and unready on Shibuya 0.9.0.3; Hackage 0.10.0.0 passes.
* **Addition**: BUG-6 records that a throwing adapter shutdown skipped sibling actions and supervisor cleanup on Shibuya core 0.9.0.3, while 0.10.0.0 passes.
* **Addition**: BUG-5 records that exhausted finalizer retries were reported as a graceful halt on Shibuya core 0.9.0.3, while 0.10.0.0 passes the fail-loud control.
* **Addition**: BUG-4 records that a finalized AckHalt cannot wake idle concurrent intake in Shibuya core 0.9.0.3, while 0.10.0.0 controls pass.
* **Addition**: BUG-3 records nonpositive Ahead/Async values removing the historical concurrency bound in Shibuya core 0.9.0.3 and the verified 0.10.0.0 rejection.
* **Addition**: BUG-2 records the historical duplicate-ID handle-loss defect in Shibuya core 0.9.0.3 and the verified 0.10.0.0 startup rejection.
* **Modification**: BUG-1 now cites clean-tree historical and current cohort runs from harness revision `5a308b6776136a702df834d944a3e770959c44c7`, each with four active handlers after stop and seven late finalizations.
* **Addition**: BUG-1 reports that forced application shutdown returns while handlers remain active and can finalize after the stop boundary on Shibuya core 0.9.0.3 and 0.10.0.0. The new bundle uses `coordination.bugReports` from okf-profiles v0.19.0.
