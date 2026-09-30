---
type: Bug Report
title: Handler halt does not wake idle intake
description: >-
  Shibuya core 0.9.0.3 can leave waitApp blocked after AckHalt when concurrent
  or batch intake is waiting on an idle source.
generated:
  by: openai/codex
  at: "2026-09-27T23:31:16Z"
bugId: BUG-4
status: fixed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya/packages/shibuya-core
capability: mori://shinzui/shibuya/okf/capabilities/concepts/CAP-2
affectedVersion: "0.9.0.3"
fixedVersion: "0.10.0.0"
resolution: >-
  The 0.10.0.0 current-release runs complete waitApp after a finalized halt
  under ahead, async and partitioned async modes with idle intake.
environment: >-
  Released Shibuya core 0.9.0.3 and Hackage 0.10.0.0 on local macOS aarch64,
  with one message followed by an idle source and a handler returning AckHalt.
observed: >-
  On 0.9.0.3, the halt decision is finalized but waitApp stays blocked in
  ahead, async and partitioned async modes until unrelated source activity or
  explicit cancellation; the owner audit also reproduces serial batching.
expected: >-
  Published CAP-2 says AckHalt stops processing entirely. Once the halt is
  finalized, the supervised processor should wake idle intake and finish
  without waiting for another message or source completion.
reproduction:
  - Run the Kenshou halt-wakes-idle-intake scenario with shibuya.concurrency=ahead:4 on the released 0.9.0.3 cohort.
  - Verify the idle-source and finalization observations, then observe waitApp remain incomplete until explicit cleanup.
  - Run ahead:4, async:4 and partitioned async:4 controls on Hackage 0.10.0.0; they pass.
workaround: >-
  On 0.9.0.3, arrange an independent stop or cancellation after a halt when the
  source can remain idle; do not rely on waitApp to return on the halt alone.
reviews:
  - kind: model
    reviewer: openai/codex
    provider: openai
    model: gpt-6
    effort: unspecified
    reviewed_at: "2026-09-30T20:36:55Z"
    document_timestamp: "2026-09-27T23:31:16Z"
    scope: catalog-metadata
    outcome: approved
    context: "Status audit of cited sealed Kenshou results, cohort package identities, later local runs, and the 2026-09-29 baseline report. Retain fixed and fixedVersion 0.10.0.0: clean published-release controls pass while historical 0.9.0.3 runs reproduce the defect. Current controls at mori://shinzui/keiro-runtime-kenshou: runs/01a0e45d-4a06-738d-a298-3b9f7e4ceba1/run-result.json, runs/01a0e45d-7b99-7793-b4ca-b1419235545f/run-result.json, runs/01a0e45d-b7bb-7518-8a3b-ec91ee765c36/run-result.json (project-relative paths; artifact-level URIs pending). Existing evidence was read; scenarios were not rerun."

---

# Handler halt does not wake idle intake

The historical released-cohort scenario `shibuya/core-runner/concurrency/halt-wakes-idle-intake` ran from `mori://shinzui/keiro-runtime-kenshou`. Clean `ahead:4` run `runs/01a0e48a-20db-77b3-a106-ad193a4d11d2/run-result.json` (artifact-level URI pending) observed the idle source and finalization but no `waitApp` completion before cleanup. Released `async:4` and partitioned `async:4` runs `runs/01a0e48a-537c-7256-8dc9-5a891ccb7bdf/run-result.json` and `runs/01a0e48a-843b-714c-bbf1-fa223d497cc2/run-result.json` reproduced the same scoped finding. The respective isolated Hackage 0.10.0.0 controls passed at `runs/01a0e45d-4a06-738d-a298-3b9f7e4ceba1/run-result.json`, `runs/01a0e45d-7b99-7793-b4ca-b1419235545f/run-result.json` and `runs/01a0e45d-b7bb-7518-8a3b-ec91ee765c36/run-result.json`. All paths are relative to the Kenshou project URI above.

Published `mori://shinzui/shibuya/okf/capabilities/concepts/CAP-2` defines `AckHalt` as stopping processing entirely. Owner `mori://shinzui/shibuya/okf/reviews/concepts/REV-4` locates the historical lost wakeup: the halt flag is written while the intake STM wait observes only inbox availability or source completion. Owner `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` requests a wakeable halt signal. This report records the failure to halt while an input source stays idle; it does not claim that every finite source hangs permanently.
