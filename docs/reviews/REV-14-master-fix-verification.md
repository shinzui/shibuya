---
type: Review
title: "Master actor removal passes the isolated garbage-collection regression"
description: "Master actor removal passes the isolated garbage-collection regression; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-14
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.Master
reviewedSha: 851c7c9db5d47593e2bd2899802c23bb06a231f7
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: approved
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Lifecycle and concurrency examination of the named component. Full refers to
  source coverage at this commit, not exhaustive testing or security certification.
  Executed probes and source-only findings are explicitly distinguished below.
---

# Master actor removal passes the isolated garbage-collection regression

Read the entire current Master module and compared its ownership to the historical REV-1 finding. The redundant mailbox, master-loop async and unconditional link are gone; the handle contains supervisor and metrics state. Register/read/unregister remain direct-state operations and stopMaster cancels the real supervisor.

## Validation

The isolated shibuya-core-gc-test passes against the locally built 0.9.0.2 working manifest at this source commit. The ordinary core suite also passes: 212 examples, zero failures. This independently validates the intended no-retained-handle GC scenario after c353a7d.

Approval is narrowly for removing the obsolete linked actor and the tested GC regression. It is not approval of the entire lifecycle surface: App ownership, halt, finalization, and health defects are separately recorded. Master registry deletion of failed processor metrics is one contributor to the Health finding, and must be redesigned with lifecycle probes rather than reverting to an idle mailbox.

Dependency supervision cleanup was checked in the local nqe-0.6.6 source archive after Mori searches found no registry entry. Its supervisor finally stops tracked children; startChild masks registration. The audit does not claim that user handlers executing uninterruptible operations can always be forcibly stopped.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
