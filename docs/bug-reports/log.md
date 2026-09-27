# Bundle Update Log

## 2026-09-27

* **Addition**: BUG-3 records nonpositive Ahead/Async values removing the historical concurrency bound in Shibuya core 0.9.0.3 and the verified 0.10.0.0 rejection.
* **Addition**: BUG-2 records the historical duplicate-ID handle-loss defect in Shibuya core 0.9.0.3 and the verified 0.10.0.0 startup rejection.
* **Modification**: BUG-1 now cites clean-tree historical and current cohort runs from harness revision `5a308b6776136a702df834d944a3e770959c44c7`, each with four active handlers after stop and seven late finalizations.
* **Addition**: BUG-1 reports that forced application shutdown returns while handlers remain active and can finalize after the stop boundary on Shibuya core 0.9.0.3 and 0.10.0.0. The new bundle uses `coordination.bugReports` from okf-profiles v0.19.0.
