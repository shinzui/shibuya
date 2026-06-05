---
id: 12
slug: release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12
title: "Release shibuya-core and shibuya-metrics 0.7.0.0 and standardize cabal-version 3.12"
kind: exec-plan
created_at: 2026-06-05T16:02:08Z
intention: "intention_01ktc7yzxhex7r1wgt15apscaz"
master_plan: "docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md"
---

# Release shibuya-core and shibuya-metrics 0.7.0.0 and standardize cabal-version 3.12

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `shibuya-core` library gained a new, breaking field on its central `Envelope`
record: `headers :: !(Maybe Headers)`, where `type Headers = [(ByteString, ByteString)]`.
This field carries every raw message header the source broker delivered, in order and
including duplicate keys. The code change is already committed to this repository (commit
`54750b2`, "feat(core)!: add headers field to Envelope") and is documented under the
`## Unreleased` heading of `shibuya-core/CHANGELOG.md`, earmarked for release `0.7.0.0`.

What does not yet exist is a *published* `0.7.0.0`. The three downstream adapter
packages — `shibuya-kafka-adapter`, `shibuya-pgmq-adapter`, and `shibuya-kiroku-adapter`,
each in its own separate git repository — depend on `shibuya-core` **from Hackage** (the
public Haskell package registry at <https://hackage.haskell.org>) via a version
constraint such as `shibuya-core ^>=0.6.0.0`. They cannot add the new `headers` field to
their own `Envelope` constructions until a `shibuya-core` that *has* the field is
available to them. This plan produces that release. After it is complete, `shibuya-core`
`0.7.0.0` and `shibuya-metrics` `0.7.0.0` are tagged in git, build cleanly, and are
published to Hackage so the adapters can bump their constraint to `^>=0.7.0.0`.

This plan also performs a second, independent piece of housekeeping the user asked for:
lowering the `cabal-version:` stanza in every `.cabal` file in *this* repository from
`3.14` to `3.12`. The `cabal-version` line is the very first line of a `.cabal` file and
tells Cabal which version of the package-description format the file uses. Some Nix
toolchains ship a `Cabal` library that predates `3.14` and reject a file that declares
`cabal-version: 3.14` with an error like `Unsupported cabal-version 3.14`. None of the
`.cabal` files in this repository use any syntax that requires `3.14` (they use only
`common` stanzas, standard `library`/`test-suite`/`benchmark` stanzas, and
`default-language: GHC2024`), so `3.12` is a safe, behavior-preserving downgrade that
unblocks those Nix users.

You can see the result working by building and testing the whole repository, building a
release tarball (`sdist`) for `shibuya-core` and `shibuya-metrics`, and confirming the
tarball's `.cabal` file reports `version: 0.7.0.0` and `cabal-version: 3.12`.

This plan is the **foundation** of master plan
`docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md`: the three
adapter-upgrade child plans (`docs/plans/13-...`, `docs/plans/14-...`, `docs/plans/15-...`)
each hard-depend on the `0.7.0.0` release this plan produces.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Downgrade `cabal-version: 3.14` → `3.12` in all four `.cabal` files in this repo.
- [ ] M1: `nix flake check` (or `cabal build all`) still succeeds with the downgraded files.
- [ ] M2: Bump `shibuya-core` and `shibuya-metrics` `version:` fields to `0.7.0.0`.
- [ ] M2: Bump the `shibuya-core ^>=0.6.0.0` constraint in `shibuya-metrics.cabal` to `^>=0.7.0.0`.
- [ ] M2: Move `shibuya-core/CHANGELOG.md` `## Unreleased` content under `## 0.7.0.0 — 2026-06-05`.
- [ ] M2: Add a `## 0.7.0.0` entry to `shibuya-metrics/CHANGELOG.md`.
- [ ] M2: Add a `## 0.7.0.0` entry to the root `CHANGELOG.md`.
- [ ] M2: `cabal build all` and `cabal test shibuya-core-test` pass; `nix fmt` applied.
- [ ] M3: `cabal sdist shibuya-core shibuya-metrics` produces tarballs; inspect their `.cabal` reports `version: 0.7.0.0`, `cabal-version: 3.12`.
- [ ] M3: Commit the release, then create annotated git tag `v0.7.0.0`.
- [ ] M3 (privileged): Publish `shibuya-core` and `shibuya-metrics` `0.7.0.0` to Hackage.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Release `shibuya-core` as `0.7.0.0` (a major-version bump in the
  four-component Haskell PVP scheme, where bumping either of the first two components
  signals a breaking change).
  Rationale: The `headers` field breaks every direct construction of `Envelope`; the
  already-committed `shibuya-core/CHANGELOG.md` `## Unreleased` section explicitly states
  "Planned next release: 0.7.0.0 (major — breaks direct `Envelope` construction)."
  Date: 2026-06-05

- Decision: Bump `shibuya-metrics` to `0.7.0.0` in lockstep even though it has no
  user-visible change of its own.
  Rationale: This repository's established convention is that `shibuya-metrics` tracks the
  `shibuya-core` version (see every prior `shibuya-metrics/CHANGELOG.md` entry, e.g.
  "0.6.0.0 — Version bumped to track shibuya-core 0.6.0.0. No user-visible changes").
  Date: 2026-06-05

- Decision: Do **not** bump `shibuya-example` (`0.1.0.0`) or `shibuya-core-bench`
  (`0.1.0.0`).
  Rationale: They are internal, unpublished packages built only from local source within
  this repository's `cabal.project`. Commit `54750b2` already added the `headers` field to
  their `Envelope` construction sites, so they already compile against the new core. They
  carry no Hackage release obligation.
  Date: 2026-06-05

- Decision: Fold the `cabal-version` `3.14` → `3.12` downgrade for this repository into
  this release plan rather than making it a separate child plan.
  Rationale: The downgrade and the release both edit the same four `.cabal` files; doing
  them together avoids a trivial standalone plan and avoids two plans racing on the same
  files. The pgmq adapter's own `3.14` → `3.12` downgrade is handled inside its upgrade
  plan (`docs/plans/14-...`) for the same self-containment reason; the kafka adapter is
  already at `3.12` and the kiroku repository is at `3.0`, so neither needs a change.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All paths in this plan are relative to this repository's root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, unless an absolute path is shown.

This repository is a Cabal multi-package project. Its `cabal.project` declares four
packages:

```text
packages:
  shibuya-core
  shibuya-core-bench
  shibuya-example
  shibuya-metrics
```

Each package has a `.cabal` file at `<package>/<package>.cabal`:

- `shibuya-core/shibuya-core.cabal` — the library; currently `version: 0.6.0.0`,
  `cabal-version: 3.14`. This is the package that gained the `headers` field. It is
  published to Hackage.
- `shibuya-metrics/shibuya-metrics.cabal` — currently `version: 0.6.0.0`,
  `cabal-version: 3.14`. Depends on `shibuya-core ^>=0.6.0.0` (line 51). Published to
  Hackage.
- `shibuya-example/shibuya-example.cabal` — `version: 0.1.0.0`, `cabal-version: 3.14`.
  Depends on `shibuya-core` with no version bound (line 37: `shibuya-core,`). Internal,
  not published.
- `shibuya-core-bench/shibuya-core-bench.cabal` — `version: 0.1.0.0`,
  `cabal-version: 3.14`. Depends on `shibuya-core` with no version bound (lines 53 and 89:
  `shibuya-core,`). Internal, not published.

The breaking change itself is the `Envelope` record in
`shibuya-core/src/Shibuya/Core/Types.hs`. As of commit `54750b2` it already has the new
field:

```haskell
-- | All message headers as delivered by the source broker, in
-- order and including duplicates.
--
-- 'Nothing' means the adapter does not surface headers at all;
-- 'Just []' means the adapter surfaces headers and this message
-- carried none.
headers :: !(Maybe Headers),
```

and the alias `type Headers = [(ByteString, ByteString)]` is exported from both
`Shibuya.Core.Types` and `Shibuya.Core`. **No source code changes are required by this
plan** — the code is already correct and tested; this plan is purely release mechanics
plus the `cabal-version` downgrade.

The `shibuya-core/CHANGELOG.md` file currently opens like this:

```markdown
# Changelog

## Unreleased

### Breaking Changes

- `Envelope` gained a `headers :: !(Maybe Headers)` field carrying every
  message header the source broker delivered, in order and including
  duplicates. ...

Planned next release: 0.7.0.0 (major — breaks direct `Envelope` construction).

## 0.6.0.0 — 2026-05-31
...
```

The root `CHANGELOG.md` aggregates per-package notes and currently opens at
`## 0.6.0.0 — 2026-05-31`. The `shibuya-metrics/CHANGELOG.md` currently opens at
`## 0.6.0.0 — 2026-05-31` with the note "Version bumped to track shibuya-core 0.6.0.0. No
user-visible changes to shibuya-metrics itself."

Build and formatting commands for this repository (from `CLAUDE.md`):

```bash
cabal build all                    # Build everything
cabal test shibuya-core-test       # Run shibuya-core tests
nix flake check                    # Run formatting/format checks
nix fmt                            # Format all files (run before committing)
```

Releases in this repository are tagged in git with a `v`-prefixed PVP version. Existing
tags are `v0.1.0.0` through `v0.6.0.0` (run `git tag` to confirm). `shibuya-core` and
`shibuya-metrics` are published to Hackage; the publish mechanism is the standard Cabal
flow (`cabal sdist`, then `cabal upload --publish`), which requires Hackage maintainer
credentials. Publishing is the only step in this plan that reaches an external service and
cannot be undone, so it is gated as a privileged step (see Validation and Acceptance).

Term definitions used below: **PVP** = the Haskell Package Versioning Policy, where a
version `A.B.C.D` signals a breaking API change by increasing `A.B`. **sdist** = "source
distribution", the `.tar.gz` release tarball Cabal builds from a package. **Hackage** =
the public registry the adapters fetch `shibuya-core` from.


## Plan of Work

The work is three milestones. M1 (cabal-version downgrade) is independent and can be done
and verified on its own. M2 (version + changelog bumps) produces the releasable state. M3
(tag + publish) makes the release real and is the artifact the adapter plans depend on.

### Milestone 1 — Standardize cabal-version to 3.12

Scope: change the first line of all four `.cabal` files from `cabal-version: 3.14` to
`cabal-version: 3.12`. At the end, the repository still builds and `nix flake check`
passes, and a Nix user whose toolchain only supports up to `3.12` is no longer blocked.

Edit the first line of each of these files:

- `shibuya-core/shibuya-core.cabal`
- `shibuya-metrics/shibuya-metrics.cabal`
- `shibuya-example/shibuya-example.cabal`
- `shibuya-core-bench/shibuya-core-bench.cabal`

In each, replace:

```text
cabal-version: 3.14
```

with:

```text
cabal-version: 3.12
```

Nothing else in those files changes in this milestone. Then rebuild to prove the format
downgrade did not break parsing.

Acceptance: `cabal build all` configures and builds with no `cabal-version`/parse error,
and `nix flake check` succeeds.

### Milestone 2 — Bump versions and finalize changelogs

Scope: bump the two published packages to `0.7.0.0`, update the one intra-repo version
constraint, and move the changelog content into dated release sections. At the end the
working tree describes a coherent `0.7.0.0` release and all tests pass.

Edits:

1. `shibuya-core/shibuya-core.cabal` line 3: `version: 0.6.0.0` → `version: 0.7.0.0`.

2. `shibuya-metrics/shibuya-metrics.cabal` line 3: `version: 0.6.0.0` → `version: 0.7.0.0`.

3. `shibuya-metrics/shibuya-metrics.cabal` line 51: `shibuya-core ^>=0.6.0.0,` →
   `shibuya-core ^>=0.7.0.0,`. (This is the only versioned intra-repo constraint;
   `shibuya-example` and `shibuya-core-bench` use an unbounded `shibuya-core,` and need no
   change. Confirm with `grep -rn "shibuya-core" --include="*.cabal" .`.)

4. `shibuya-core/CHANGELOG.md`: rename the `## Unreleased` heading to
   `## 0.7.0.0 — 2026-06-05`, keep its `### Breaking Changes` body, and **delete** the
   trailing line `Planned next release: 0.7.0.0 (major — breaks direct Envelope
   construction).` (that planning note has now been realized). The result should read:

   ```markdown
   # Changelog

   ## 0.7.0.0 — 2026-06-05

   ### Breaking Changes

   - `Envelope` gained a `headers :: !(Maybe Headers)` field carrying every
     message header the source broker delivered, in order and including
     duplicates. Direct constructions of `Envelope` must add the field.
     `Nothing` means the adapter does not surface headers; `Just []` means
     it does and the message had none. The new `Headers` type alias
     (`[(ByteString, ByteString)]`) is exported from `Shibuya.Core` and
     `Shibuya.Core.Types`. The W3C trace headers continue to appear in
     `traceContext` as before; they now also appear verbatim in `headers`.

   ## 0.6.0.0 — 2026-05-31
   ...
   ```

5. `shibuya-metrics/CHANGELOG.md`: insert a new top entry above `## 0.6.0.0`:

   ```markdown
   ## 0.7.0.0 — 2026-06-05

   Version bumped to track `shibuya-core` 0.7.0.0. No user-visible changes
   to `shibuya-metrics` itself.
   ```

6. Root `CHANGELOG.md`: insert a new top entry above `## 0.6.0.0 — 2026-05-31`:

   ```markdown
   ## 0.7.0.0 — 2026-06-05

   ### Breaking Changes

   - `shibuya-core`: `Envelope` gained a `headers :: !(Maybe Headers)` field
     carrying every message header the source broker delivered, in order and
     including duplicates. Direct constructions of `Envelope` must add the
     field. `Nothing` means the adapter does not surface headers; `Just []`
     means it does and the message had none. The new `Headers` type alias
     (`[(ByteString, ByteString)]`) is exported from `Shibuya.Core` and
     `Shibuya.Core.Types`.

   ### Other Changes

   - All `.cabal` files in this repository now declare `cabal-version: 3.12`
     instead of `3.14`, so Nix toolchains whose bundled Cabal predates 3.14
     can build the packages. No package-description syntax that requires 3.14
     was in use, so this is behavior-preserving.
   - `shibuya-metrics` is re-released at 0.7.0.0 to track the shared version;
     it has no user-visible changes of its own.
   ```

Acceptance: `cabal build all` succeeds, `cabal test shibuya-core-test` is green, and
`nix fmt` leaves the tree formatted (re-stage if it reformats anything).

### Milestone 3 — Build sdists, tag, and publish

Scope: produce the release tarballs, commit, tag, and (as a gated privileged step) upload
to Hackage. At the end, `shibuya-core 0.7.0.0` and `shibuya-metrics 0.7.0.0` exist as a
git tag and — once the user authorizes the upload — on Hackage, which is precisely the
artifact the three adapter plans need.

Steps (commands in Concrete Steps):

1. `cabal sdist shibuya-core shibuya-metrics` and inspect the generated tarballs' `.cabal`
   to confirm `version: 0.7.0.0` and `cabal-version: 3.12`.
2. Commit all changes with the conventional-commit + trailers shown in Concrete Steps.
3. Create an annotated tag `v0.7.0.0`.
4. **Privileged, do not run without explicit user authorization:** upload to Hackage. This
   publishes to an external registry and cannot be undone.

Acceptance: the tag `v0.7.0.0` exists; the sdists carry the right version; after upload,
`https://hackage.haskell.org/package/shibuya-core-0.7.0.0` resolves.


## Concrete Steps

Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` inside the Nix dev shell (the
project's `nix develop` environment, which provides `cabal`, GHC 9.12.4, and `nix fmt`).

Milestone 1:

```bash
# Edit the four cabal-version lines (use your editor or sed). Verify afterwards:
grep -rn "cabal-version" --include="*.cabal" . | grep -v dist-newstyle
# Expect all four to read: cabal-version: 3.12

cabal build all
nix flake check
```

Milestone 2:

```bash
# After editing versions, constraint, and changelogs, confirm the constraint:
grep -rn "shibuya-core" --include="*.cabal" . | grep -v dist-newstyle
# Expect shibuya-metrics.cabal to show: shibuya-core ^>=0.7.0.0,

cabal build all
cabal test shibuya-core-test
nix fmt        # then re-stage any reformatted files
```

Milestone 3:

```bash
# Build release tarballs
cabal sdist shibuya-core shibuya-metrics
# The command prints paths under dist-newstyle/sdist/. Inspect the core tarball:
tar -xzf dist-newstyle/sdist/shibuya-core-0.7.0.0.tar.gz -O shibuya-core-0.7.0.0/shibuya-core.cabal | head -5
# Expect lines: cabal-version: 3.12 / name: shibuya-core / version: 0.7.0.0

# Commit (note both MasterPlan and ExecPlan trailers, plus Intention):
git add -A
git commit -m "chore(release): release shibuya-core and shibuya-metrics 0.7.0.0

Finalize the 0.7.0.0 changelog (Envelope gained the headers field),
bump shibuya-core and shibuya-metrics to 0.7.0.0, bump the
shibuya-metrics -> shibuya-core constraint to ^>=0.7.0.0, and lower
cabal-version from 3.14 to 3.12 across the repo for Nix compatibility.

MasterPlan: docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md
ExecPlan: docs/plans/12-release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12.md
Intention: intention_01ktc7yzxhex7r1wgt15apscaz"

git tag -a v0.7.0.0 -m "shibuya-core and shibuya-metrics 0.7.0.0"
```

Privileged publish step — **only after the user explicitly authorizes it**, because it
reaches Hackage irreversibly:

```bash
# Build docs and upload candidates first if desired, then publish:
cabal upload --publish dist-newstyle/sdist/shibuya-core-0.7.0.0.tar.gz
cabal upload --publish dist-newstyle/sdist/shibuya-metrics-0.7.0.0.tar.gz
# (Haddock docs: cabal haddock --haddock-for-hackage shibuya-core, then
#  cabal upload --publish --documentation <generated-docs-tarball>)
```


## Validation and Acceptance

The change is effective when:

1. Every `.cabal` file's first line is `cabal-version: 3.12`
   (`grep -rn "cabal-version" --include="*.cabal" . | grep -v dist-newstyle` shows four
   matches, all `3.12`).
2. `shibuya-core/shibuya-core.cabal` and `shibuya-metrics/shibuya-metrics.cabal` both
   declare `version: 0.7.0.0`, and `shibuya-metrics.cabal` constrains
   `shibuya-core ^>=0.7.0.0`.
3. `cabal build all` succeeds and `cabal test shibuya-core-test` reports all examples
   passing (the suite includes round-trip tests for the new `headers` field added in
   commit `54750b2`, e.g. in `shibuya-core/test/Shibuya/Core/TypesSpec.hs`). Expected
   tail of the test output is a summary line such as `Examples: N  Failures: 0`.
4. `cabal sdist shibuya-core shibuya-metrics` produces
   `dist-newstyle/sdist/shibuya-core-0.7.0.0.tar.gz` and
   `dist-newstyle/sdist/shibuya-metrics-0.7.0.0.tar.gz`, and the extracted `.cabal` from
   the core tarball reports `cabal-version: 3.12` / `version: 0.7.0.0`.
5. The annotated git tag `v0.7.0.0` exists (`git tag | grep v0.7.0.0`).
6. After the privileged upload, `https://hackage.haskell.org/package/shibuya-core-0.7.0.0`
   and `.../shibuya-metrics-0.7.0.0` resolve. This step is the hard dependency the adapter
   plans wait on; until it completes, adapters can still develop against a git-pinned
   `shibuya-core` (see this plan's note in the master plan's Integration Points), but they
   cannot publish their own releases.


## Idempotence and Recovery

M1 and M2 edits are pure text edits and safe to re-run or re-apply; if a build fails after
them, `git diff` shows exactly what changed and `git checkout -- <file>` reverts a single
file. `cabal sdist` is read-only with respect to source and overwrites its own output
tarball, so it is safe to repeat. Creating the git tag is local and reversible with
`git tag -d v0.7.0.0` before it is pushed. The **only** irreversible action is
`cabal upload --publish`: a published Hackage version cannot be deleted or overwritten, so
treat it as a one-way door and run it only with explicit authorization and after every
other acceptance check is green. If a mistake is discovered after publishing, the recovery
path is a new patch release (`0.7.0.1`), never an overwrite.


## Interfaces and Dependencies

This plan publishes, but does not change, the following interface that the three adapter
plans consume:

- Module `Shibuya.Core.Types` (re-exported by `Shibuya.Core`):
  - `type Headers = [(ByteString, ByteString)]`
  - `data Envelope msg = Envelope { messageId :: !MessageId, cursor :: !(Maybe Cursor),
    partition :: !(Maybe Text), enqueuedAt :: !(Maybe UTCTime),
    traceContext :: !(Maybe TraceHeaders), headers :: !(Maybe Headers),
    attempt :: !(Maybe Attempt), attributes :: !(HashMap Text Attribute), payload :: !msg }`

After this plan, the contract for downstream adapters is: a published `shibuya-core`
`0.7.0.0` whose `Envelope` has the `headers` field, available from Hackage. The adapter
plans `docs/plans/13-...`, `docs/plans/14-...`, and `docs/plans/15-...` each hard-depend on
that contract.
