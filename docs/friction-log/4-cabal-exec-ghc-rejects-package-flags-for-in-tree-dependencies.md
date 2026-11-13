---
type: Friction Entry
title: "cabal exec ghc rejects -package flags for in-tree dependencies"
description: "Compiling a one-file diagnostic against the worktree's shibuya-core with cabal exec -- ghc failed while any project dependency was named with -package, costing several rebuild attempts."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T05:02:32Z"
frictionId: FRIC-4
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya"
plan: "docs/plans/61-reduce-the-async-dispatch-allocation-increase-introduced-in-0-13-0-0.md"
workaround: "Pass only packages outside the build plan (here -package ghc-heap) and rely on the environment file cabal exec loads for everything else; pass -XGHC2024 -XNoFieldSelectors by hand since cabal's default-extensions do not apply."
---
# cabal exec ghc rejects -package flags for in-tree dependencies

## Attempted

Build a stack-decoding probe executable linked against the worktree's in-place shibuya-core with cabal exec -- ghc -package shibuya-core -package effectful-core -package streamly-core ...

## Encountered

GHC reported 'Ambiguous module name Effectful ... found in multiple packages: effectful-core-2.7.1.2 effectful-core-2.7.1.2' (and the same for streamly-core), because the cabal-generated package environment already exposes the plan's units and -package adds the store copy.

```text
Ambiguous module name 'Streamly.Data.Stream'. it was found in multiple packages: streamly-core-0.3.3 streamly-core-0.3.3
```

## Workaround

Pass only packages outside the build plan (here -package ghc-heap) and rely on the environment file cabal exec loads for everything else; pass -XGHC2024 -XNoFieldSelectors by hand since cabal's default-extensions do not apply.
