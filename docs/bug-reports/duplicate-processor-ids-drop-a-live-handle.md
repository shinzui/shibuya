---
type: Bug Report
title: Duplicate processor IDs discard a live application handle
description: >-
  Shibuya core 0.9.0.3 starts two processors with the same ID and stores only
  one handle, so the other processor is omitted from application shutdown.
generated:
  by: openai/codex
  at: "2026-09-27T23:09:08Z"
bugId: BUG-2
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-3
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The current 0.10.0.0 application rejects duplicate IDs before either source
  is pulled; the sealed current-release Kenshou scenario passes.
environment: >-
  Released Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with one ordinary and one batch processor sharing the same ProcessorId.
observed: >-
  On 0.9.0.3 runApp accepts both processors and pulls a source. The application
  constructs a map keyed by ProcessorId after starting both, discarding one
  live handle; the owner's lifecycle probe observes that the first adapter
  receives no shutdown call.
expected: >-
  The published CAP-3 named-processor application must retain every started
  processor for introspection and shutdown. Rejecting duplicate IDs before
  startup is the current implementation's safe resolution.
reproduction:
  - Run the Kenshou duplicate-processor-ids-are-rejected scenario on the released 0.9.0.3 cohort.
  - The scenario gives runApp an ordinary and a batching processor with the same ProcessorId and observes acceptance and source pull.
  - Run the same scenario on Hackage 0.10.0.0; it returns a rejection before either source is pulled.
workaround: >-
  Assign a unique ProcessorId to every processor, including ordinary and batch
  processors, before calling runApp.
---

# Duplicate processor IDs discard a live application handle

The historical released-cohort scenario `shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected` ran from `mori://shinzui/keiro-runtime-kenshou` with `nix develop -c cabal run -v0 kenshou -- run shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected --out runs`. Its sealed `runs/01a0cefa-42e2-730d-8528-20619beecaa7/run-result.json` (artifact-level URI pending) reproduced the duplicate-ID failure with the ordinary/batch mixture. A later released-cohort sweep repeated it at `runs/01a0e478-fc24-7455-b29b-552eccf2dadb/run-result.json`; the pinned head passed at `runs/01a0e485-6fcf-7394-8c5e-ab3b343c6914/run-result.json`. The isolated Hackage 0.10.0.0 CLI run passed at `runs/01a0e458-680b-732d-8c5d-fdbb283c0502/run-result.json`. All paths are relative to the Kenshou project URI above.

The released result's precise failure label is `REV-3-F2`, with reason `runApp accepted invalid configuration; source was pulled before validation`; its harness revision is `871bf6fb8a03bfae43260843d39a221fa4ea7733` and its Hackage `shibuya-core` source digest is `sha256:497e3698632c13ed674df2c81a1d9ea3090c05ab43bc4deb0b718ce7d585eca7`. The current result passed with no failure labels at harness revision `8481bbc8529f69745a4afa3d9f13b0fc5ade6071` and Hackage source digest `sha256:fde7bd013d1c6e9652bdf66571cd9b17771b26494e33d982c744a9621208471e`. This smoke scenario has no user knobs or telemetry dimensions and covers `startup-registration/synchronousException`.

The [published CAP-3](../capabilities/supervised-processing-with-backpressure.md) promises a handle for introspection and shutdown of a list of named processors. The [owner REV-3 probe](../reviews/REV-3-app-runtime-audit.md) directly observed the discarded handle and missing first-adapter shutdown in the older implementation; `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requested startup identity validation. The current rejection preserves the promised ownership boundary. This report is limited to core 0.9.0.3 and does not allege a current-release failure.
