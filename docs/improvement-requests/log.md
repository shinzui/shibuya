# Bundle Update Log

## 2026-09-30
* **Update**: Accept IR-3, IR-4, and IR-5 and link them to `docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`; child plans EP-47 through EP-52 deliver them and `docs/adr/0007` records Shibuya's own wire contract.

## 2026-09-25
* **Addition**: IR-8 requests a separate retry-decision metric while preserving the documented `processed` counter mapping.
* **Addition**: IR-7 records the cross-release transient-handler-exception state and readiness failure reproduced by keiro-runtime-kenshou.

## 2026-09-20
* **Update**: Mark the route and WebSocket contract test-suite deliverable complete while leaving configurable CORS and broader convention alignment proposed.
* **Addition**: Add IR-6 for the confirmed lifecycle, concurrency, and health audit gaps.

## 2026-08-19
* **Addition**: Harden shibuya-metrics for browser clients - CORS, tests, and WS convention alignment (IR-5) filed from keiro-ui
* **Addition**: Implement designed processor pause/resume and expose gated control endpoints (IR-4) filed from keiro-ui
* **Addition**: Expose processor progress, latency, and in-flight detail for inspection UIs (IR-3) filed from keiro-ui

## 2026-08-10
* **Addition**: IR-2 requests an honest application-defined permanent-processing reason for
`AckDeadLetter`, originating from
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-9`.

## 2026-07-30
* **Addition**: IR-1 requests a public worker probe contract for service health integration.
