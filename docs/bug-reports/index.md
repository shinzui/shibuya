---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Disabled WebSocket endpoint still accepts upgrades](disabled-websocket-endpoint-still-upgrades.md) - Shibuya metrics 0.9.0.3 accepts WebSocket upgrades even when its enableWebSocket configuration flag is false.
- [Duplicate processor IDs discard a live application handle](duplicate-processor-ids-drop-a-live-handle.md) - Shibuya core 0.9.0.3 starts two processors with the same ID and stores only one handle, so the other processor is omitted from application shutdown.
- [Exhausted finalizer is reported as a graceful halt](exhausted-finalizer-reported-as-graceful-halt.md) - Shibuya core 0.9.0.3 converts permanent finalizer failure into a normal processor halt, hiding the failure from StopAllOnFailure supervision.
- [Forced application stop returns while handlers can still finalize](forced-stop-returns-before-handlers-finish.md) - With four handlers blocked in the current batch, a forced application stop returns while those handlers are still active; opening their gate later lets them finalize after the caller was told the application had stopped.
- [Handler halt does not wake idle intake](halt-does-not-wake-idle-intake.md) - Shibuya core 0.9.0.3 can leave waitApp blocked after AckHalt when concurrent or batch intake is waiting on an idle source.
- [Health probes ignore terminal processor and master state](health-probes-ignore-terminal-lifecycle.md) - Shibuya metrics 0.9.0.3 reports readiness after a configured processor fails and liveness after the application master stops.
- [Nonpositive concurrency removes the handler bound](nonpositive-concurrency-removes-handler-bound.md) - Shibuya core 0.9.0.3 accepts zero and negative Async or Ahead bounds and can run concurrent handlers beyond the configured limit.
- [Stale activity marks healthy processing stuck](stale-activity-marks-healthy-processing-stuck.md) - Shibuya 0.9.0.3 retains an old processing-burst timestamp and can report actively progressing processors as stuck and unready.
- [Throwing adapter shutdown skips sibling cleanup](throwing-adapter-shutdown-skips-siblings.md) - Shibuya core 0.9.0.3 lets one adapter shutdown exception skip later adapter shutdown actions and supervisor cleanup during graceful stop.
- [WebSocket disconnect leaks connection slots](websocket-disconnect-leaks-connection-slots.md) - Shibuya metrics 0.9.0.3 can retain a WebSocket connection slot after setup failure or peer disconnect, eventually denying new clients at the limit.
- [WebSocket unsubscribe still delivers selected updates](websocket-unsubscribe-all-still-delivers-updates.md) - Shibuya metrics 0.9.0.3 continues to stream a processor's updates after an Unsubscribe frame following subscribe-all.

