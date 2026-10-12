# Bundle Update Log

## 2026-10-12
* **Update**: Record optional progress HTTP and WebSocket evidence
* **Update**: Record bounded acknowledged cursor progress and runner evidence

## 2026-10-10
* **Update**: Record optional latency and oldest-in-flight members and series evidence
* **Update**: Record bounded opt-in latency and in-flight accounting evidence
* **Update**: Bound outbound frames and bytes, add in-band errors and adjacent snapshot recovery, and enforce send/shutdown deadlines; queue and controlled transport tests plus protocol mapping added.
* **Update**: CAP-10 gains configurable cross-origin access with WebSocket upgrade origin validation; CorsSpec added as evidence.

## 2026-09-20
* **Update**: Replace the working-but-unproven caveat with release-gated HTTP, golden, frame, and real WebSocket test evidence; retain browser/CORS and convention limits.

## 2026-08-08
* **Addition**: Establish the capability bundle — CAP-1 through CAP-10 describe what Shibuya
provides today, each with the released version it arrived in, its compatibility promise, and
evidence a reader can open.
* **Model**: Adopt the shared `coordination.capabilities` profile from
[okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles), pinned by Dhall semantic
hash. Provision claims only: absent capabilities stay in the improvement-request bundle,
and there is deliberately no `planned` status.
