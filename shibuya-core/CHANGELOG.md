# Changelog

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- Multi-queue processing with `runApp` and `QueueProcessor` API
- Backpressure via bounded inbox
- AckHalt support to stop processing on halt decision
- Serial, Ahead, and Async concurrent processing modes
- Policy validation enforcement (StrictInOrder requires Serial)
- Graceful shutdown with configurable drain timeout
- NQE-based supervision via Master/Supervisor
- OpenTelemetry tracing integration with W3C trace context propagation
- Mock adapter for testing

### Bug Fixes

- Fix race conditions and incomplete cleanup in runner
- Fix data races in concurrent test handlers using atomicModifyIORef'

### Other Changes

- Consolidate error handling with unified error types
- Define own SupervisionStrategy type to decouple from NQE
- Use registerDelay for cleaner timeout handling
- Replace polling with STM blocking in waitApp
