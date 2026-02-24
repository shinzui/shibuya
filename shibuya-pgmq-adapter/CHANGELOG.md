# Changelog

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- PGMQ adapter for PostgreSQL message queue integration
- Visibility timeout-based leasing with automatic retry handling
- Optional dead-letter queue support
- Configurable prefetching via PrefetchConfig
- Concurrent prefetching with streamly parBuffered
- OpenTelemetry trace context propagation
- Topic routing support (pgmq-hs 0.1.1.0)
- Comprehensive test suite with property-based and integration tests

### Bug Fixes

- Fix batch wastage using streamly unfoldEach
