---
type: Review
title: "Runtime audit confirms lost processor handles and exception-unsafe lifecycle cleanup"
description: "Runtime audit confirms lost processor handles and exception-unsafe lifecycle cleanup; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-3
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.App
reviewedSha: 851c7c9db5d47593e2bd2899802c23bb06a231f7
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Lifecycle and concurrency examination of the named component. Full refers to
  source coverage at this commit, not exhaustive testing or security certification.
  Executed probes and source-only findings are explicitly distinguished below.
produced:
  - mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6
---

# Runtime audit confirms lost processor handles and exception-unsafe lifecycle cleanup

Read App in full, with Internal.App, Master, Supervised and the dependency exception implementation as supporting evidence. Source matches the reviewed commit; the working Cabal manifest labels the same source 0.9.0.2.

## Findings

- **P1 — shutdown cleanup is skipped on exceptions.** App.hs:287 calls adapters sequentially, outside any cleanup guarantee. A throwing adapter prevents subsequent shutdown calls and the stopMaster at line 297. LifecycleProbe prints `(True,Nothing,False)`: shutdown threw, waitApp did not complete, second shutdown was not called. Explicit stopMaster cleans up the fixture afterwards. Cancellation during the drain also bypasses cleanup by the same control flow; that interleaving was not injected.
- **P2 — duplicate IDs discard live handles.** Map.fromList at line 194 keeps the last entry after all children have started. The probe prints `(Just (),True,False)`: waitApp returns, graceful drain reports success, and the first adapter never receives shutdown. Metrics registration/unregistration also collides. Reject duplicates before startup, including mixed batch/non-batch entries.
- **P1 — startup ownership is not cancellation-safe (source evidence).** After startMaster, child acquisition and handle return are not masked/bracketed. The imported UnliftIO try/catch explicitly exclude asynchronous exceptions, so cancellation during spawn bypasses stopMaster. Already-spawned children can survive the caller. This is not a claim that a deterministic cancellation probe was run.

The shutdown timeout starts after adapter shutdown actions; it is only a drain timeout, not a total shutdown bound. Decide the latter contract separately.

## Evidence and disposition

Runtime script: `scripts/audit/LifecycleProbe.hs`; commands and output are in the audit report. Ordinary halt and source-failure supervision tests remain green in the 212-example suite. REV-2 remains the earlier source-only examination; this is a new full examination with executable evidence, not an edit of that historical claim. Duplicate handle construction dates to 60b2d45 and graceful shutdown to 4539898; these are not introduced by the current GC fix. Remediation and regression acceptance: IR-6.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
