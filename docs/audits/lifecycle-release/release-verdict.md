# Shibuya lifecycle release verdict

Verdict: **APPROVED FOR RELEASE**

Candidate: `shibuya-lifecycle-0.10.0.0-rc2`  
Dossier commit: `f3de2cdbbb1efe1ef984e98cd562d29a5e0edfa3`  
Independent review: [REV-17](../../reviews/REV-17-rc2-release-assurance-review.md)

## Exact release cohort

| Package | Version | Source revision |
| --- | --- | --- |
| shibuya-core | 0.10.0.0 | `e28a95893a534a15302529850eea54f6e0682de0` |
| shibuya-metrics | 0.10.0.0 | `e28a95893a534a15302529850eea54f6e0682de0` |
| shibuya-kafka-adapter | 0.9.1.0 | `adadf9f52c7ca235fc41f5d7d3e95494735530ab` |
| shibuya-pgmq-adapter | 0.16.1.0 | `6ce44abb28c983ede774ac8c6a9ada9c96b0a65f` |
| kiroku-store | 0.8.0.2 | `407cb223f7ba5007d36cc77550d8489a1ae7206d` |
| shibuya-kiroku-adapter | 0.5.1.3 | `407cb223f7ba5007d36cc77550d8489a1ae7206d` |

Unified solver-plan SHA-256:
`1ebf23d528595d2fed2b3cf6492a5ca03efeec80229b168edc023122cc730e27`.

## Gate result

The release validator passes all 52 inventory records, 15 lifecycle boundaries,
and 70 mandatory cells. Thirty-three fixed findings pass candidate-bound evidence;
14 accepted limitations, assumptions, or verification boundaries have matching
named human decisions; the five MessageDB records are explicitly out of scope.
A stale source-SHA mutation is rejected in all evidence runs.

Functional evidence includes 236 Core examples, 52 Metrics examples, both
process-isolated GC suites, 1,600 deterministic schedules, 53 Kafka tests, 177
PGMQ examples, 308 Kiroku Store examples, and 38 Kiroku adapter examples under the
required RTS cells and live services.

Performance evidence passes all 84 paired cells under N1 and all 84 under N4,
all nine sustainable/saturation/soak adapter cells, 100,000 real readiness
requests, and 10,000 real WebSocket cycles. External delivery ledgers report zero
duplicate, missing, unexpected, or malformed identities and zero final backlog.
No performance budget changed and no waiver was used.

## Residual risks and unsupported configurations

- Distinct in-progress batch-key cardinality is caller-bounded rather than
  implementation-bounded. The release owner accepted the conservative observed
  envelope of 703 bytes per additional key over 1,000–50,000 keys for Shibuya
  0.10.x through 2026-12-31 or before 0.11.0.0, whichever occurs first.
- Kafka is serial, provides no adapter DLQ producer, and requires the documented
  rebalance fencing helper for cooperative rebalancing.
- PGMQ and Kiroku provide at-least-once behavior; interruption can replay work.
- Uninterruptible user code can exceed normal shutdown guarantees.
- Metrics has no built-in authentication. Binding beyond loopback is an explicit
  operator deployment decision.
- The MessageDB adapter is deprecated, unsupported, and uncertified. REV-12 is
  excluded, not fixed or waived.

## Upgrade, rollback, and publication

Core 0.10.0.0 is a PVP-major release because it adds exported lifecycle error
constructors and changes lifecycle semantics. Adapters contain committed Core
0.10 bounds. Rollback therefore means restoring the previous package cohort and
its bounds together; do not mix a 0.10-only adapter build with Core 0.9. PGMQ and
Kiroku preserve their documented durable replay/checkpoint behavior across the
upgrade.

Publication order is:

1. shibuya-core 0.10.0.0
2. shibuya-metrics 0.10.0.0
3. shibuya-kafka-adapter 0.9.1.0 and shibuya-pgmq-adapter 0.16.1.0
4. kiroku-store 0.8.0.2
5. shibuya-kiroku-adapter 0.5.1.3

Metrics and every adapter must wait until Core is visible on Hackage. The Kiroku
adapter must additionally wait until Kiroku Store 0.8.0.2 is visible. A runtime
source or dependency-solution change after this verdict requires a new candidate
and fresh affected evidence.
