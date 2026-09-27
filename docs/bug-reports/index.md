---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Duplicate processor IDs discard a live application handle](duplicate-processor-ids-drop-a-live-handle.md) - Shibuya core 0.9.0.3 starts two processors with the same ID and stores only one handle, so the other processor is omitted from application shutdown.
- [Forced application stop returns while handlers can still finalize](forced-stop-returns-before-handlers-finish.md) - With four handlers blocked in the current batch, a forced application stop returns while those handlers are still active; opening their gate later lets them finalize after the caller was told the application had stopped.
- [Nonpositive concurrency removes the handler bound](nonpositive-concurrency-removes-handler-bound.md) - Shibuya core 0.9.0.3 accepts zero and negative Async or Ahead bounds and can run concurrent handlers beyond the configured limit.

