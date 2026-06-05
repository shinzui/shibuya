---
id: 2
slug: headers-field-adapter-upgrade-and-core-0-7-0-0-release
title: "Headers Field Adapter Upgrade and Core 0.7.0.0 Release"
kind: master-plan
created_at: 2026-06-05T16:01:54Z
intention: "intention_01ktc7yzxhex7r1wgt15apscaz"
---

# Headers Field Adapter Upgrade and Core 0.7.0.0 Release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`shibuya-core` recently gained a breaking change: its central `Envelope` record now has a
`headers :: !(Maybe Headers)` field (where `type Headers = [(ByteString, ByteString)]`)
that carries every raw message header the source broker delivered, in order and including
duplicate keys. The code is already committed to the `shibuya` repository (commit
`54750b2`) and documented under `## Unreleased` in `shibuya-core/CHANGELOG.md`, earmarked
for release `0.7.0.0`. What is missing is a *published* `0.7.0.0` and the propagation of
that change to the adapters that build `Envelope`s.

After this initiative is complete:

- `shibuya-core 0.7.0.0` and `shibuya-metrics 0.7.0.0` are tagged and published to Hackage,
  carrying the new `headers` field.
- All three in-scope adapters compile and are released against `shibuya-core 0.7.0.0`, each
  setting the new field correctly: the **Kafka** adapter surfaces real Kafka headers
  verbatim (`Just [...]`); the **PGMQ** and **Kiroku** adapters report `Nothing` because
  their backing stores have no ordered, raw broker-header stream.
- Every `.cabal` file that previously declared `cabal-version: 3.14` (the `shibuya`
  repository and the `shibuya-pgmq-adapter` repository) now declares `3.12`, so Nix
  toolchains whose bundled Cabal predates `3.14` can build the packages.

Scope boundary. Included: the `shibuya` repo release + cabal-version downgrade; the Kafka,
PGMQ, and Kiroku adapter upgrades (each in its own git repository). Explicitly excluded:
the `shibuya-message-db-adapter` (the user asked to ignore it this round); the Kafka repo's
`cabal-version` (already `3.12`) and the Kiroku repo's (already `3.0`), neither of which
needs changing; and any new handler-facing API beyond reading the already-defined field.


## Decomposition Strategy

The initiative was split by **functional concern and by independently releasable
artifact**, which here aligns with repository boundaries — each adapter is its own git
repository with its own release cadence, and the core is a fourth. This yields four child
plans:

1. The **core release** (`docs/plans/12-...`) is the foundation: it publishes the
   `shibuya-core 0.7.0.0` that every adapter must build against, and folds in this repo's
   `cabal-version` downgrade because the release already edits these `.cabal` files.

2–4. One plan per **adapter** (`docs/plans/13-...` Kafka, `docs/plans/14-...` PGMQ,
   `docs/plans/15-...` Kiroku). Each is fully self-contained for its repository: bump the
   `shibuya-core` constraint, add the `headers` field at the single `Envelope` construction
   site, add a test, version, and release.

Principles applied. *Minimize cross-plan coupling*: no two plans edit the same file —
they live in different repositories and share only the `shibuya-core` API contract. *Maximize
independent verifiability*: each adapter plan is provable on its own with `cabal build` +
`cabal test` once the core is available. *Respect natural ordering*: the adapters cannot
compile the new field until a `shibuya-core` that has it exists, so the core release is a
hard dependency of all three.

The `cabal-version` `3.14` → `3.12` downgrade was deliberately **not** made its own plan.
It is a tiny, repo-local edit that naturally rides along with each repository's other cabal
edits: the `shibuya` repo's downgrade lives in the core-release plan, and the PGMQ repo's
lives in its adapter plan. The Kafka repo (already `3.12`) and Kiroku repo (already `3.0`)
need no change. Centralizing it in a standalone plan would have forced two plans to touch
the same `.cabal` files in two repositories, violating the minimize-coupling principle; the
cross-cutting nature is instead recorded in Integration Points below.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Release shibuya-core and shibuya-metrics 0.7.0.0 and standardize cabal-version 3.12 | docs/plans/12-release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12.md | None | None | Complete (local); Hackage publish owned by user |
| 2 | Upgrade shibuya-kafka-adapter for Envelope headers field | docs/plans/13-upgrade-shibuya-kafka-adapter-for-envelope-headers-field.md | EP-1 | None | Complete (local); Hackage publish owned by user |
| 3 | Upgrade shibuya-pgmq-adapter for Envelope headers field and cabal-version 3.12 | docs/plans/14-upgrade-shibuya-pgmq-adapter-for-envelope-headers-field-and-cabal-version-3-12.md | EP-1 | None | Complete (local); Hackage publish owned by user |
| 4 | Upgrade shibuya-kiroku-adapter for Envelope headers field | docs/plans/15-upgrade-shibuya-kiroku-adapter-for-envelope-headers-field.md | EP-1 | None | Complete (local); Hackage publish owned by user |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 (core release) is the root. EP-2, EP-3, and EP-4 each hold a **hard** dependency on
EP-1: an adapter that adds `headers = ...` to its `Envelope` construction will not
type-check until a `shibuya-core` containing the `headers` field is resolvable, and the
adapters resolve `shibuya-core` from Hackage. The artifact EP-1 must produce for them is
therefore a published `shibuya-core 0.7.0.0` (the git tag `v0.7.0.0` plus the Hackage
upload).

There are **no** dependencies among EP-2, EP-3, and EP-4. They live in three separate
repositories, touch disjoint files, and can be implemented in parallel — by different
sessions or contributors — the moment EP-1's `0.7.0.0` is available. A contributor who
wants to start an adapter before the Hackage upload has propagated can temporarily pin
`shibuya-core` from git (tag `v0.7.0.0`) via a `source-repository-package` stanza, develop
and test against it, and remove the pin before publishing the adapter; each adapter plan
documents this escape hatch in its Idempotence and Recovery section.

Phases: **Phase 1** is EP-1 alone. **Phase 2** is EP-2, EP-3, EP-4 in parallel.


## Integration Points

**IP-1 — The `shibuya-core` `Envelope`/`Headers` contract (EP-1 defines; EP-2, EP-3, EP-4
consume).** The shared artifact is the `shibuya-core` public API in module
`Shibuya.Core.Types` (re-exported by `Shibuya.Core`): the alias
`type Headers = [(ByteString, ByteString)]` and the `Envelope` record's new field
`headers :: !(Maybe Headers)`. EP-1 owns this — the field is already committed in
`shibuya-core/src/Shibuya/Core/Types.hs`; EP-1 publishes it as `0.7.0.0`. The adapters must
consume it identically: bump their `shibuya-core` constraint to admit `0.7.x`, then set the
field at their one `Envelope` construction site. The agreed semantics of the field's value,
which all three adapters must honor, are: `Nothing` = "this adapter does not surface broker
headers"; `Just []` = "this adapter surfaces headers and this message carried none";
`Just [...]` = the verbatim ordered, duplicate-allowing broker headers. Kafka (EP-2) uses
`Just (headersToList cr.crHeaders)`; PGMQ (EP-3) and Kiroku (EP-4) use `Nothing` because
their stores expose no such stream (their JSONB metadata feeds `traceContext`/`partition`
instead).

**IP-2 — `cabal-version: 3.12` standardization (cross-cutting; EP-1 and EP-3 each apply it
locally).** The shared concern is that every `.cabal` file currently declaring
`cabal-version: 3.14` must move to `3.12` for Nix compatibility. There is no single owner
because no file is shared across plans; instead each plan applies the downgrade within its
own repository: EP-1 downgrades the four `.cabal` files in the `shibuya` repo; EP-3
downgrades the three `.cabal` files in the `shibuya-pgmq-adapter` repo. EP-2's repo is
already `3.12` and EP-4's is `3.0`, so they perform no downgrade. The reconciliation rule:
after the initiative, a repo-wide `grep -rn "cabal-version"` across all touched
repositories should show only `3.12` (or the pre-existing `3.0` in Kiroku), never `3.14`.

**IP-3 — Pre-Hackage local verification via git pin (EP-1 produces the tag; EP-2/3/4 may
consume it before Hackage propagation).** Until EP-1's `cabal upload --publish` completes
and propagates, the adapters can build against the `v0.7.0.0` git tag using a temporary
`source-repository-package` stanza pointing at the `shibuya` repo's `shibuya-core` and
`shibuya-metrics` subdirs. This is a development convenience only; every adapter plan
requires removing the pin before that adapter is itself published, so released adapters
depend solely on the Hackage `shibuya-core 0.7.0.0`.

A coordination note on git trailers: implementation commits for EP-2/3/4 land in the
*adapter* repositories, but their `MasterPlan:` and `ExecPlan:` trailers reference the plan
paths as they exist in the `shibuya` repository (e.g.
`docs/plans/13-upgrade-shibuya-kafka-adapter-for-envelope-headers-field.md`). The
`Intention:` trailer is `intention_01ktc7yzxhex7r1wgt15apscaz` on every commit across all
repos.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

Phase 1 — core release (must complete before Phase 2):

- [x] EP-1 M1: `cabal-version` 3.14 → 3.12 across the `shibuya` repo; build still green. (2026-06-05)
- [x] EP-1 M2: bumped shibuya-core/shibuya-metrics to 0.7.0.0, finalized changelogs; 118 tests green. (2026-06-05)
- [~] EP-1 M3: sdists built, committed `8ed1257`, `v0.7.0.0` tagged. Hackage publish BLOCKED on user authorization.

Phase 2 — adapter upgrades (parallel, each hard-depends on EP-1):

- [x] EP-2 M1: Kafka — bumped constraint to ^>=0.7.0.0 and populated `headers = Just (headersToList cr.crHeaders)`; build green. (2026-06-05)
- [x] EP-2 M2: Kafka — tests prove headers round-trip verbatim (order + duplicates) and empty→`Just []`; 28 tests green. (2026-06-05)
- [~] EP-2 M3: Kafka — version 0.7.0.0, changelog, committed `424a4c2`, tagged `v0.7.0.0`. Hackage publish owned by user.
- [x] EP-3 M1: PGMQ — cabal-version 3.12, bumped constraints to ^>=0.7.0.0, `headers = Nothing`; build green. (2026-06-05)
- [x] EP-3 M2: PGMQ — tests prove `headers == Nothing` (incl. non-empty JSONB); Convert spec 22 green. (2026-06-05)
- [~] EP-3 M3: PGMQ — version 0.7.0.0, changelog, committed `48c27ba`, tagged `v0.7.0.0`. Hackage publish owned by user.
- [x] EP-4 M1: Kiroku — bound to >=0.7 && <0.8 (adapter + kiroku-store bench), `headers = Nothing`; build green. (2026-06-05)
- [x] EP-4 M2: Kiroku — test proves `headers == Nothing` (incl. with trace metadata); toEnvelope suite 5 green. (2026-06-05)
- [x] EP-4 M3: Kiroku — version 0.3.0.0, changelog, committed `90bd3bc`, tagged `shibuya-kiroku-adapter-v0.3.0.0`.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Each adapter has exactly **one** `Envelope` construction site, so each adapter change is
  a one-line field addition plus a dependency bump — the bulk of every adapter plan is
  release mechanics, not code. (Evidence: research found a single constructor in each repo —
  `consumerRecordToEnvelope`, `pgmqMessageToEnvelope`, `toEnvelope` respectively.)
- Only the Kafka adapter has real broker headers available at its construction site
  (`cr.crHeaders`, already converted via `headersToList` for trace extraction), so it is the
  only adapter that populates the field with data; PGMQ and Kiroku back onto PostgreSQL
  stores with JSONB metadata objects, not ordered header streams, hence `Nothing`.
- Local pre-Hackage verification (IP-3) needs the local `shibuya-metrics` pinned alongside
  `shibuya-core` whenever the adapter repo builds a package that depends on
  `shibuya-metrics`. In `shibuya-pgmq-adapter`, `shibuya-pgmq-example` depends on
  `shibuya-metrics`, so pinning only `shibuya-core` left `shibuya-metrics 0.6.0.0` (Hackage)
  dragging `shibuya-core` back to `0.6.0.0` and the solver failed; pinning both local
  sources and bumping the example's `shibuya-metrics` constraint to `^>=0.7.0.0` resolved
  it. The kafka repo did not hit this (it has no `shibuya-metrics` dependency). Watch for
  the same in any adapter that uses `shibuya-metrics`.
- pgmq `headers` decision confirmed with the user as `Nothing`; a forward-looking note about
  optionally surfacing producer-supplied pgmq headers was added to the adapter code and
  EP-3's Decision Log so the option is not lost.
- The "one Envelope construction site per repo" assumption held for kafka and pgmq but
  **not** for kiroku: `kiroku-store`'s `kiroku-shibuya-overhead` benchmark also constructs
  an `Envelope` and depends on `shibuya-core`. With `benchmarks: True` in the repo's
  `cabal.project`, that second site had to be updated (field + `>=0.7 && <0.8` bound) before
  the adapter would resolve. Lesson for any future `Envelope`-field rollout: grep the entire
  adapter repo (all packages, including benchmarks) for `shibuya-core` and `Envelope`, not
  just the adapter package.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into four child plans — one core release plus one per in-scope
  adapter (Kafka, PGMQ, Kiroku) — along repository/release-artifact boundaries.
  Rationale: Each adapter is an independently releasable package in its own git repository;
  splitting this way maximizes independent verifiability and keeps cross-plan file coupling
  at zero (the only shared artifact is the upstream `shibuya-core` API).
  Date: 2026-06-05

- Decision: Make the core release (EP-1) a hard dependency of all three adapter plans.
  Rationale: Adapters resolve `shibuya-core` from Hackage and cannot compile the new
  `headers = ...` field until a `shibuya-core` containing the field is published; the
  adapters' own releases must not depend on an unpublished source.
  Date: 2026-06-05

- Decision: Do not make the `cabal-version` 3.14 → 3.12 downgrade a standalone plan;
  fold it into EP-1 (shibuya repo) and EP-3 (pgmq repo).
  Rationale: It is a repo-local one-line-per-file edit that rides along with each repo's
  other cabal edits; a standalone plan would force two plans to touch the same files in two
  repos. Recorded as cross-cutting Integration Point IP-2 instead. Kafka (already 3.12) and
  Kiroku (already 3.0) need no change.
  Date: 2026-06-05

- Decision: Exclude `shibuya-message-db-adapter` from this initiative.
  Rationale: The user explicitly asked to ignore the message-db adapter this round. It can
  be upgraded in a follow-up using EP-3/EP-4 as templates (it will almost certainly use
  `headers = Nothing`).
  Date: 2026-06-05

- Decision: Use intention `intention_01ktc7yzxhex7r1wgt15apscaz` for all plans and commits
  across all repositories in this initiative.
  Rationale: The user supplied this Intention ID for the session.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

As of 2026-06-05 all four child plans are implemented and locally verified:

- EP-1: `shibuya-core`/`shibuya-metrics` `0.7.0.0` — built, 118 tests green, changelogs
  finalized, `cabal-version` 3.12 across the repo, committed `8ed1257`, tagged `v0.7.0.0`,
  sdists built.
- EP-2: `shibuya-kafka-adapter` `0.7.0.0` — `headers` populated verbatim from Kafka, 28
  tests green, committed `424a4c2`, tagged `v0.7.0.0`.
- EP-3: `shibuya-pgmq-adapter` `0.7.0.0` — `headers = Nothing`, `cabal-version` 3.12, Convert
  spec 22 green, committed `48c27ba`, tagged `v0.7.0.0`.
- EP-4: `shibuya-kiroku-adapter` `0.3.0.0` — `headers = Nothing` (adapter + kiroku-store
  benchmark), `toEnvelope` suite 5 green, committed `90bd3bc`, tagged
  `shibuya-kiroku-adapter-v0.3.0.0`.

The vision is met against the original scope, with one outstanding gate: the **Hackage
publishes are owned by the user** and not yet performed. The release order is `shibuya-core`
+ `shibuya-metrics` `0.7.0.0` first, then the three adapters (which depend on the core being
on Hackage). Each adapter was verified locally against a temporary `shibuya-core` source pin
that was removed before its release commit, so every released `.cabal` depends solely on
Hackage. The `shibuya-message-db-adapter` remains out of scope per the user's instruction
and can reuse EP-3/EP-4 as templates (almost certainly `headers = Nothing`).

Lessons: (1) when rolling out a new `Envelope` field, grep every package in each adapter
repo — benchmarks included — for `shibuya-core`/`Envelope`, since the "one construction
site" assumption broke for kiroku. (2) Local pre-Hackage verification must pin every local
Shibuya package that participates in the solve (e.g. `shibuya-metrics` for pgmq), not just
`shibuya-core`.
