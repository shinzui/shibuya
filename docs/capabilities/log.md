# Bundle Update Log

## 2026-08-08

* **Addition**: Establish the capability bundle — CAP-1 through CAP-10 describe what Shibuya
  provides today, each with the released version it arrived in, its compatibility promise, and
  evidence a reader can open.
* **Model**: Adopt the shared `coordination.capabilities` profile from
  [okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles), pinned by Dhall semantic
  hash. Provision claims only: absent capabilities stay in the improvement-request bundle,
  and there is deliberately no `planned` status.
