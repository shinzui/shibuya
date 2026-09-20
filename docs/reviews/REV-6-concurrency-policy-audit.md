---
type: Review
title: "Nonpositive concurrency values are accepted and can remove concurrency limits"
description: "Nonpositive concurrency values are accepted and can remove concurrency limits; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-6
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Policy
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

# Nonpositive concurrency values are accepted and can remove concurrency limits

Read the full Policy module and traced its uses in App, Supervised and BatchProcessor.

## P2 — invalid limits change the resource bound

validatePolicy checks only StrictInOrder versus non-Serial combinations. Unordered Async/Ahead values of zero or negative are accepted. The unordered runner passes n and 2*n directly to Streamly maxThreads/maxBuffer. Streamly uses zero for a default limit and negative values for unlimited, whereas keyed/batch paths clamp to at least one.

A finite 20-message probe with blocking handlers observes peak concurrency 20 for Async (-1), 20 for Async 0, 1 for Async 1, and 2 for Async 2. All four calls are accepted and finish. This confirms the mismatch in the installed execution path, rather than relying solely on a dependency checkout.

Reject nonpositive concurrency before startup, and guard derived-size overflow for very large positive values. Add equivalent Ahead, partitioned and batch validation tests. No claim of an observed out-of-memory incident is made.

Dependency source: `mori://composewell/streamly`, project-relative `streamly/src/Streamly/Internal/Data/Stream/Channel/Type.hs` (file artifact URI pending), maxThreads/maxBuffer definitions. No dependency bounds were changed. IR-6 tracks remediation.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
