---
type: Review
title: "Kiroku adapter release packaging preserves the approved runtime candidate"
description: "Independent supplemental review approves the packaging-only successor used for the Kiroku adapter release."
generated:
  by: process:codex-cli
  at: "2026-09-22T13:58:00Z"
reviewId: REV-18
subject: mori://shinzui/kiroku/packages/shibuya-kiroku-adapter
subjectKind: component
component: shibuya-kiroku-adapter 0.5.1.3 release packaging
reviewedSha: c96194c451199536db71533c2c15f7c92ff5b963
coverage: incremental
baseSha: 407cb223f7ba5007d36cc77550d8489a1ae7206d
previousReview: REV-17
reviewedAt: "2026-09-22T13:58:00Z"
reviewerKind: model
reviewer: process:codex-cli/candidate-review
provider: openai
model: gpt-6-astra
effort: high
outcome: approved
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Supplemental release review of the packaging-only Kiroku adapter successor
  discovered during Hackage source-distribution rehearsal. Focused covers the
  exact diff from behavioral candidate 407cb22 to c96194c, package flags,
  dependency bounds, source-tree identity, repository gates, and an isolated
  Hackage-resolved sdist build. It does not repeat RC2 runtime performance work.
---

# Kiroku adapter release packaging preserves the approved runtime candidate

## Verdict

Approved. No blocking finding remains for adapter release tag target
`c96194c451199536db71533c2c15f7c92ff5b963`.

## Finding and correction

The first isolated source-distribution rehearsal rejected the adapter because
the new `lifecycle-live` release fixture was a default-build executable and
depended on unpublished `kiroku-test-support`. The correction adds a manual
`lifecycle-live` flag that defaults off for source-distribution consumers while
the checked-in Kiroku project enables it for repository assurance runs.

## Candidate bridge

- The adapter runtime-source tree is identical at behavioral candidate
  `407cb223f7ba5007d36cc77550d8489a1ae7206d` and packaging successor
  `c96194c451199536db71533c2c15f7c92ff5b963`; both resolve to tree
  `fce3bf8aa7d4f6226773a089033f75f616e2b6bd`.
- The complete `kiroku-store` tree is also identical, at tree
  `160f6f6e8aab0bd3b9c257b29d422da8655bb0f7`.
- Public adapter library dependencies, bounds, and version remain unchanged.
  The only changed files are the repository project, adapter Cabal metadata,
  and its changelog.

The original Store tag therefore remains on `407cb22`; only the adapter tag
uses `c96194c`.

## Evidence checked

- The repository project still builds the live fixture and the full project;
  all 38 adapter examples pass and the Nix checks pass.
- `cabal check` reports only the pre-existing advisory for the fixture's `-O2`.
- The regenerated sdist contains the default-off flag and conditional.
- An isolated library build from that sdist downloads and builds published
  `kiroku-store 0.8.0.2` and `shibuya-core 0.10.0.0` from Hackage without
  resolving the unpublished test-support package.

This packaging-only successor neither changes the approved runtime behavior nor
requires the RC2 runtime/performance matrix to be repeated.
