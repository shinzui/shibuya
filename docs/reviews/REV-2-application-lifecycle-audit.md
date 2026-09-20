---
type: Review
title: Application lifecycle audit finds shutdown cleanup and duplicate identity defects
description: Source review of App identifies lost processor handles and missing exception-safe shutdown cleanup; runtime reproduction remains pending.
generated:
  by: process:codex-cli
  at: "2026-09-20T03:21:08Z"
reviewId: REV-2
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.App
repository: mori://shinzui/shibuya/repos/shibuya
reviewedSha: afdf42ece83e0765ed00c663801146737acff52f
coverage: full
reviewedAt: "2026-09-20T03:21:08Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - design
  - test-coverage
  - operability
context: >-
  Full source examination of Shibuya.App, with supporting inspection of
  Internal.App, Master, Supervised, and lifecycle tests. Findings below are
  established by control flow, not newly executed reproductions. Full coverage
  refers to this module, not completion of the ongoing cross-component audit.
---

# Application lifecycle findings

## F1 — High: a shutdown exception bypasses supervisor cleanup

At `shibuya-core/src/Shibuya/App.hs:287`, `stopAppGracefully` invokes adapter
shutdown actions sequentially. The call to `stopMaster` at line 297 is not
protected by `finally` or another cleanup guarantee. If an adapter's shutdown
throws, later adapters are not signalled, draining is skipped, and the master
and remaining processors are not stopped by this operation. Cancellation while
waiting for drain likewise bypasses `stopMaster`.

This is a source-confirmed exception-safety defect. The `Adapter.shutdown`
contract does not prohibit throwing. No runtime reproduction has yet been run
for this finding.

Recommended correction: guarantee supervisor cleanup on exceptional exit,
attempt shutdown of all adapters even if one fails, and retain/report the
original failure. Define cancellation behavior explicitly rather than swallowing
asynchronous exceptions.

Required regression: use two live processors; make the first adapter shutdown
throw; verify the second is signalled and both children terminate. Also cancel
shutdown during draining and verify no children remain.

An additional operational limitation is that the drain timeout starts only after
all adapter shutdown actions return. A blocking shutdown can therefore prevent
force-stop indefinitely. The field documents a *drain* timeout, so this review
does not treat it as an established violation of a total shutdown deadline;
decide and document the overall deadline separately.

## F2 — Medium: duplicate processor IDs silently discard lifecycle handles

`runApp` validates configuration and policies but not identity uniqueness.
`spawnProcessors` starts every list entry, then `Map.fromList` at line 194
keeps only the last entry for each ID. Consequently, an earlier processor still
belongs to the supervisor but is absent from the handle used by `waitApp` and
adapter shutdown. `waitApp` can report completion while that processor is still
running, and its adapter never receives the normal shutdown signal.

Supporting inspection shows metrics are also keyed by the same ID: registration
overwrites the previous entry and either processor's unregister can remove the
other's metrics. Force-stopping the master still cancels supervised children;
this finding is not a claim that duplicate-ID children escape the supervisor.

This is source-confirmed; no duplicate-ID runtime probe has yet been run.

Recommended correction: reject duplicate IDs before acquiring the master or
starting any processor. Required regression: duplicate IDs return a structured
configuration error with zero adapter/handler startup effects, for ordinary,
batch, and mixed processor entries.

## Pending investigation, not another confirmed finding

Startup has multiple acquisition steps (`startMaster`, child creation, handle
assembly). Audit asynchronous cancellation between those steps and verify the
exception semantics of the underlying libraries before concluding whether a
supervisor can leak. The synchronous spawn-failure branch does call `stopMaster`.

## Evidence and limits

Read the entire App module and traced the paths above into the supporting
modules. Existing lifecycle tests cover finite-source halt, explicit cancellation,
and supervision policies; the tests inspected do not establish exception-safe
adapter shutdown or duplicate-ID rejection. No new runtime test result is
claimed by this record. Production code was not changed by this audit.

These findings are independent of the removed idle master mailbox. The original
GC defect is recorded in [REV-1](REV-1-master-lifecycle-gc-regression.md).
The wider audit is still underway; see [audit progress](../lifecycle-audit-progress.md).
