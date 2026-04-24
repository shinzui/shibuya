# Split shibuya-pgmq-adapter into its own repository

Intention: intention_01kg953t69enps79pj77taz6nw

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

Today the PGMQ adapter, its benchmarks, and its runnable example all live inside the
main `shibuya` repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
Every `shibuya-core` release therefore forces a coordinated release of
`shibuya-pgmq-adapter`, and vice versa — e.g. `shibuya-core 0.2.0.0` and
`shibuya-pgmq-adapter 0.2.0.0` were cut together purely because they shared a repo
(see `CHANGELOG.md`: "shibuya-core and shibuya-metrics are re-released at 0.3.0.0
to track the shared version; neither has user-visible changes of its own").

This plan decouples the two so that the adapter can release on its own cadence and
track the `pgmq-hs` client library independently, matching the split that already
exists for the Kafka adapter at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

After this plan the reader can:

1. `cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` and run
   `cabal build all && cabal test shibuya-pgmq-adapter-test` successfully against
   a local PGMQ-capable PostgreSQL.
2. `cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` and run
   `cabal build all && cabal test` successfully *without* the PGMQ packages
   present; the remaining `cabal.project` packages are `shibuya-core`,
   `shibuya-core-bench`, `shibuya-example`, `shibuya-metrics`.
3. Run `mori registry list` and see two distinct `own` entries:
   `shinzui/shibuya` (no PGMQ packages) and `shinzui/shibuya-pgmq-adapter`
   (three packages).
4. Read `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/README.md` and
   see a clear "Adapters" section linking to both the Kafka adapter repo and
   the new PGMQ adapter repo on GitHub.

This is a refactor/split — no functional behavior of the adapter changes. The
observable-outcome validation is therefore (a) the new repo builds and tests
green, (b) the shrunk `shibuya` repo builds and tests green, and (c) `mori
registry` reflects the new topology.


## Progress

- [x] **Milestone 1 — Scaffold the new repository skeleton.** (2026-04-24)
  - [x] Create `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/`.
  - [x] Copy package directories (`shibuya-pgmq-adapter/`,
        `shibuya-pgmq-adapter-bench/`, `shibuya-pgmq-example/`) from `shibuya`.
  - [x] Write top-level `cabal.project`, `flake.nix`, `treefmt.nix`,
        `Justfile`, `process-compose.yaml`, `.envrc`, `.gitignore`, `LICENSE`,
        `README.md`, `CHANGELOG.md`, `mori.dhall`, `fourmolu.yaml`.
  - [x] `mori validate` clean; `mori register --local` registered the repo.
        No `mori/repo-id` file was minted — see Surprises.
  - [x] Initialize git (`git init -b master`, initial commit `<initial sha>`).
- [x] **Milestone 2 — Build, test, and verify the new repository in
      isolation.** `cabal build all` and `cabal test shibuya-pgmq-adapter-test`
      green (112 examples, 0 failures) against `ephemeral-pg`-spun
      PostgreSQL. Required bumping `shinzui/hasql-migration` pin to
      `4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c` and deleting the
      frozen resolver — see Surprises. (2026-04-24)
- [x] **Milestone 3 — Remove the extracted packages from `shibuya`.**
      (2026-04-24)
  - [x] Edit `shibuya/cabal.project` to drop the three packages and the
        hasql 1.10 `source-repository-package` entries. Also removed
        `cabal.project.freeze` (see Surprises — hasql-migration bump).
  - [x] Edit `shibuya/mori.dhall` to drop the three packages, the
        `shinzui/pgmq-hs` and `hasql/hasql` top-level dependencies, the
        `adapter-dev` agent hint, and shrink the `shibuya-full` bundle
        to `shibuya-core` + `shibuya-metrics`.
  - [x] `rm -rf` the three package directories in `shibuya`.
  - [x] `cabal build all && cabal test shibuya-core-test` in `shibuya`
        pass (92 examples, 0 failures).
  - [x] `mori validate` clean; `mori register --local` refreshed the
        registry entry (now 4 packages).
- [x] **Milestone 4 — Relocate PGMQ-specific documentation.**
      (2026-04-24)
  - [x] Moved `shibuya/docs/user/pgmq-*.md` (4 files) and
        `shibuya/docs/pgmq-adapter/*` (5 files) into the new repo
        under `docs/user/` and `docs/pgmq-adapter/` respectively.
  - [x] Updated `shibuya/README.md`: dropped PGMQ doc bullets from the
        Documentation section, retargeted the Optional Packages
        `shibuya-pgmq-adapter` bullet to the new repo, added a Kafka
        adapter bullet for symmetry, added an "Adapters" section, and
        amended the 0.3.0.0 What's New bullet to flag the split.
  - [x] Updated `docs/USAGE_GUIDE.md` and `docs/user/README.md` to
        replace the removed PGMQ links with pointers to the new repo.
  - [x] Prepended an `Unreleased / Repo Layout` section to
        `shibuya/CHANGELOG.md` documenting the split and the
        `cabal.project.freeze` deletion.
- [x] **Milestone 5 — Final verification and commit discipline.**
      (2026-04-24)
  - [x] `nix fmt` in both repos reports 0 files changed.
  - [x] Pre-commit hook (`treefmt`) bundled into the flake passed on
        commit in both repos.
  - [x] `mori registry show shinzui/shibuya --full` shows 4 packages
        (core / core-bench / example / metrics); `mori registry show
        shinzui/shibuya-pgmq-adapter --full` shows 3 packages
        (adapter / adapter-bench / example).


## Surprises & Discoveries

- **2026-04-24 — `mori register --local` does not mint `mori/repo-id`.**
  The plan (inherited from a pattern in the kafka-adapter repo, which
  has `mori/repo-id = repo_01kpevwqcaek4v7b5327tevkz7`) expected
  `mori register --local` to write that file. In practice it only
  registers into the local registry database; the `repo_…` identifier
  appears to be minted by the non-`--local` form that talks to the
  remote registry. Evidence: running `mori register --local` in the
  new repo printed `Project registered: shinzui/shibuya-pgmq-adapter`
  but no `mori/` directory was created, and `mori registry show
  shinzui/shibuya-pgmq-adapter` reports `Repo ID: —`. No blocker: the
  local registry works fine without it. If/when we want a remote
  `repo_…` we can run `mori register` (no `--local`) later and add
  the resulting `mori/repo-id` file to the repo in a follow-up commit.
- **2026-04-24 — `fourmolu.yaml` needed alongside `treefmt.nix`.**
  The `shibuya` repo has a top-level `fourmolu.yaml` governing style
  (indentation 2, trailing commas, etc). Without copying it into the
  new repo, treefmt would fall back to fourmolu defaults and produce
  diff on every Haskell file. Copied it verbatim from `shibuya/`.
- **2026-04-24 — The old `hasql-migration` pin breaks against an
  unfrozen resolver.** Shibuya's `cabal.project` pinned
  `shinzui/hasql-migration` at `ab66f6ae…`, which predates the
  `crypton 1.x` migration (commit `eb866025`). In the existing
  `shibuya` repo this was masked by `cabal.project.freeze` pinning
  `crypton 1.0.6`. In the new repo — built without a freeze file —
  cabal happily picked `crypton 1.1.2`, which dropped the
  `ByteArrayAccess (Digest MD5)` instance that the old
  `hasql-migration` depended on, so the build failed with
  `No instance for 'Data.ByteArray.Types.ByteArrayAccess (crypton-1.1.2:Crypto.Hash.Types.Digest MD5)'`.
  Fix: bump the pin to
  `4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c` (latest master, includes
  the crypton 1.x migration plus GHC2024 cabal modernization) in both
  `shibuya/cabal.project` and
  `shibuya-pgmq-adapter/cabal.project`, and delete both freeze files
  so the resolver tracks the current dependency graph going forward.
- **2026-04-24 — `cabal test` needs the test suite enabled.** A
  fresh `cabal test shibuya-pgmq-adapter-test` in the new repo
  failed with `Cabal-7043 Cannot test the test suite … because the
  solver did not find a plan that included the test suites`. Passing
  `--enable-tests` on the first invocation made it resolve and run
  cleanly (112 examples, 0 failures). Not a plan-level issue — once
  `dist-newstyle/cache/plan.json` includes the test suite, subsequent
  runs work without the flag. Worth documenting in the new repo's
  README as a "first run" note if we keep hitting it.


## Decision Log

- Decision: Copy the three package directories plain, without preserving
  per-file git history via `git filter-repo` or `git subtree split`.
  Rationale: The user asked for this explicitly (see "History mode" prompt
  answered 2026-04-24). It matches the observed pattern at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`,
  which contains no historical commits from `shibuya`. Keeps the split
  fast and low-risk.
  Date: 2026-04-24.

- Decision: Keep the `hs-opentelemetry` `source-repository-package`
  entries in `shibuya/cabal.project` but remove the hasql 1.10 ecosystem
  entries. Rationale: `shibuya-core/shibuya-core.cabal` depends on
  `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, and
  `hs-opentelemetry-semantic-conventions` — none of which are on Hackage
  for GHC 9.12 yet. The hasql entries (`hasql`, `hasql-pool`,
  `hasql-transaction`, `hasql-migration`) are only consumed by
  `shibuya-pgmq-adapter`, `shibuya-pgmq-adapter-bench`, and
  `shibuya-pgmq-example`, so they move with those packages.
  Date: 2026-04-24.

- Decision: The new repo inherits version `0.3.0.0` for
  `shibuya-pgmq-adapter` (unchanged from current `cabal` file) and keeps
  `shibuya-pgmq-adapter-bench` / `shibuya-pgmq-example` at `0.1.0.0`.
  Rationale: The repo split itself does not change the adapter's
  user-visible API or behavior. Bumping to `0.3.1.0` or `0.4.0.0` on move
  would muddy release notes. Future releases from the new repo decide
  independently when to bump.
  Date: 2026-04-24.

- Decision: Relocate PGMQ-specific user docs (`docs/user/pgmq-*.md`,
  `docs/pgmq-adapter/*`) into the new repo rather than leaving them in
  `shibuya`. Rationale: Docs belong with the code that implements their
  subject; the Kafka adapter repo already follows this pattern (its
  Jitsurei examples double as user docs). `shibuya/README.md` links to
  the new repo for PGMQ content.
  Date: 2026-04-24.

- Decision: Move `shibuya-pgmq-example` (with its `simulator` and
  `consumer` executables) into the new repo alongside the adapter.
  Rationale: The user explicitly said "move the adapter and the example
  packages". It mirrors the kafka-adapter's
  `shibuya-kafka-adapter-jitsurei` placement. Keeps the example testable
  against the adapter it demonstrates without reaching into a sibling
  repo.
  Date: 2026-04-24.


## Outcomes & Retrospective

**Close-out — 2026-04-24**

The split landed in four commits:

- `shibuya-pgmq-adapter@4f92e55` — initial import from
  `shinzui/shibuya@e426e00`.
- `shibuya-pgmq-adapter@d0ffb0d` — `build: bump hasql-migration to
  4aaff6c (crypton 1.x)`.
- `shibuya-pgmq-adapter@49e9476` — `docs: import PGMQ user guides from
  shinzui/shibuya`.
- `shibuya@5a66aa1` — `chore(pgmq-adapter)!: split into
  shinzui/shibuya-pgmq-adapter`.

Observable outcomes versus the plan's purpose statement:

1. **New repo builds and tests green.** `cabal build all` succeeds,
   `cabal test shibuya-pgmq-adapter-test --enable-tests` returns
   `112 examples, 0 failures`.
2. **Shrunk `shibuya` still builds and tests green.**
   `cabal test shibuya-core-test` returns `92 examples, 0 failures`.
3. **`mori registry list` shows both `own` entries.** Both `--full`
   listings render the expected topology (4 vs 3 packages).
4. **`shibuya/README.md` has a clear Adapters section** linking both
   adapter repos.

Things we got right:

- Copying the package directories verbatim (vs. `git filter-repo`)
  kept the split fast and low-risk; the kafka-adapter precedent was
  the right model.
- Validating the new repo in isolation (Milestone 2) **before**
  deleting anything from `shibuya` was load-bearing. Without that
  sequence the hasql-migration/crypton failure would have surfaced
  after the rollback path was already gone.

Things the plan did not anticipate (recorded in Surprises &
Discoveries):

- `mori register --local` does not mint `mori/repo-id`. The new repo
  is usable locally without one; we can add it later if we ever run
  non-local `mori register`.
- `fourmolu.yaml` is not picked up by `treefmt.nix` and has to be
  copied in alongside it. Added to the scaffold step.
- The old `shinzui/hasql-migration` pin (`ab66f6a`) only built
  because `shibuya/cabal.project.freeze` was pinning `crypton 1.0.6`.
  Upgrading the pin to `4aaff6c` (post-crypton-1.x-migration) and
  dropping the freeze file in both repos was necessary for a clean
  unfrozen build going forward.
- `cabal test` in a fresh `dist-newstyle` requires `--enable-tests`
  the first time through.

Lessons for the next adapter split (if there is one):

- **Pre-flight the resolver unfrozen.** Before copying packages,
  temporarily rename `cabal.project.freeze` in the source repo and
  run `cabal build all` to surface pin rot early. The hasql-migration
  incident could have been caught in planning.
- **Keep `fourmolu.yaml`/`.gitignore`/flake-lock checklist explicit.**
  The plan named most top-level files but missed `fourmolu.yaml`.
- **Record the doc targets that still reference moved files.**
  `docs/USAGE_GUIDE.md` and `docs/user/README.md` were not in the
  plan's move list but needed updating. A simple `grep -rl pgmq
  docs/` before the split would have caught both.


## Context and Orientation

### The shibuya project

`shibuya` is a supervised queue-processing framework for Haskell. Its root
lives at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The
`cabal.project` currently declares seven packages:

    packages:
      shibuya-core
      shibuya-core-bench
      shibuya-example
      shibuya-metrics
      shibuya-pgmq-adapter
      shibuya-pgmq-adapter-bench
      shibuya-pgmq-example

After this plan it will declare only four: `shibuya-core`,
`shibuya-core-bench`, `shibuya-example`, `shibuya-metrics`.

### The three packages being moved

1. `shibuya-pgmq-adapter` (version 0.3.0.0, cabal-version 3.14) —
   library at `shibuya-pgmq-adapter/`. Exposes
   `Shibuya.Adapter.Pgmq`, `Shibuya.Adapter.Pgmq.Config`,
   `Shibuya.Adapter.Pgmq.Convert`; test suite `shibuya-pgmq-adapter-test`
   uses `ephemeral-pg` and `pgmq-migration` to spin up a real
   PostgreSQL. Build-depends on `shibuya-core ^>=0.3.0.0`,
   `pgmq-core ^>=0.2`, `pgmq-effectful ^>=0.2`, `pgmq-hasql ^>=0.2`,
   `effectful-core`, `streamly`, etc.
2. `shibuya-pgmq-adapter-bench` (version 0.1.0.0) — at
   `shibuya-pgmq-adapter-bench/`. Provides a `tasty-bench` benchmark
   (`bench/Main.hs`) and an `endurance-test` executable (`app/Endurance.hs`).
   Depends on `shibuya-core`, `shibuya-pgmq-adapter`, `pgmq-migration`,
   `tasty-bench`.
3. `shibuya-pgmq-example` (version 0.1.0.0) — at `shibuya-pgmq-example/`.
   A runnable demo with two executables, `shibuya-pgmq-simulator` (app/)
   and `shibuya-pgmq-consumer`, plus a small internal library
   (`src/Example/*`). Depends on `shibuya-core`, `shibuya-metrics`,
   `shibuya-pgmq-adapter`, the `hs-opentelemetry-*` trio, `pgmq-migration`.

### What the reference repo looks like

The Kafka adapter is already a standalone repo at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Its
top-level tree is:

    shibuya-kafka-adapter/                  (actual Haskell library package)
    shibuya-kafka-adapter-bench/            (tasty-bench micro-benchmarks)
    shibuya-kafka-adapter-jitsurei/         (runnable examples)
    cabal.project                           (names the three packages)
    flake.nix                               (GHC 9.12 dev shell, rdkafka)
    treefmt.nix                             (fourmolu + cabal-fmt + nixpkgs-fmt)
    Justfile                                (process-up, create-topics, test, bench)
    process-compose.yaml                    (redpanda + jaeger)
    mori.dhall                              (standalone project identity)
    mori/repo-id                            (mori-issued identifier)
    mori/cookbook.dhall                     (cookbook catalog, optional)
    .envrc                                  (`use flake` + `eval "$shellHook"`)
    .gitignore                              (dist-newstyle, .direnv, .claude, ...)
    LICENSE
    README.md
    docs/plans/                             (execution plans)

The new PGMQ repo will mirror that shape almost exactly, swapping
Kafka/Redpanda-specific pieces for PostgreSQL/PGMQ ones.

### Mori in one paragraph for readers who do not know it

`mori` is the user's personal project-identity + dependency-resolution
tool (installed as a CLI on the `PATH`). Each project carries a
`mori.dhall` file that names packages, dependencies, docs, and "agent
hints", plus a `mori/repo-id` file (an opaque `repo_…` identifier that
mori mints at first registration). Running `mori register --local`
ingests the config into a local registry database so that
`mori registry list|search|show` can answer questions like "where does
the source of `shinzui/pgmq-hs` live on disk?" We touch mori for four
reasons in this plan: (1) create the new repo's `mori.dhall`, (2)
register the new repo so queries reflect it, (3) shrink `shibuya`'s
`mori.dhall` to drop the moved packages, and (4) validate both.

### Key files you will edit

In `shibuya`:

- `cabal.project` — drop three package lines + hasql
  `source-repository-package` entries.
- `mori.dhall` — drop three packages, two deps (`shinzui/pgmq-hs`,
  `hasql/hasql`), the `adapter-dev` agent hint, and shrink
  `shibuya-full` bundle.
- `README.md` — drop PGMQ doc links in the Documentation section, drop
  the 0.3.0.0 PGMQ bullet from "What's New", add an Adapters section.
- `CHANGELOG.md` — add a new entry documenting the repo split.

In the new repo (all new files):

- `cabal.project`, `flake.nix`, `treefmt.nix`, `Justfile`,
  `process-compose.yaml`, `.envrc`, `.gitignore`, `LICENSE`,
  `README.md`, `CHANGELOG.md`, `mori.dhall`.


## Plan of Work

The work proceeds in five milestones. Each milestone leaves both
repositories in a buildable state (except that the extracted packages
are duplicated across both between milestones 1 and 3 — this is
deliberate: it lets milestone 2 validate the new repo in isolation
before any deletion).

### Milestone 1: Scaffold the new repository

Create the new repo at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/`.

Create the empty directory with `mkdir`. Copy the three package
directories verbatim from `shibuya`, using `cp -a` (or `rsync -a`) so
permissions and timestamps are preserved:

    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/
    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter-bench \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/
    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-example \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/

Then, at the new repo root, create:

- `cabal.project` — lists the three packages and carries the
  `source-repository-package` entries for hs-opentelemetry and hasql
  1.10. Exact content in Concrete Steps below.
- `flake.nix` — based on
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/flake.nix`
  (since it already has the Postgres + process-compose shellHook), but
  with `PGDATABASE=shibuya_pgmq_adapter`, `treefmtEval` wired up, and a
  dev-shell description appropriate to the new repo.
- `treefmt.nix` — the two-line passthrough style used by
  `shibuya-kafka-adapter/treefmt.nix` (`fourmolu + cabal-fmt +
  nixpkgs-fmt`).
- `Justfile` — recipes `process-up`, `process-down`, `build`, `test`,
  `bench`, `fmt`, plus PGMQ-specific `create-database`, `psql`,
  `drop-database` modelled on `shibuya/Justfile`.
- `process-compose.yaml` — a postgres process plus optional jaeger,
  derived from `shibuya/process-compose.yaml` and
  `shibuya-kafka-adapter/process-compose.yaml`.
- `.envrc` — `use flake\neval "$shellHook"` (verbatim from
  `shibuya-kafka-adapter/.envrc`).
- `.gitignore` — include `dist-newstyle/`, `.direnv/`, `.dev/`, `db/`,
  `.envrc` (direnv caches), `.pre-commit-config.yaml`, `.claude/`,
  `CLAUDE.local.md`.
- `LICENSE` — copy from
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/LICENSE`.
- `README.md` — derived from the Kafka adapter README, retargeted to
  PGMQ (quickstart, packages list, `just` recipes, layout, license).
- `CHANGELOG.md` — new file with a single entry "0.3.0.0 — initial
  release as a standalone repository (extracted from `shinzui/shibuya`
  at commit `<sha>`)". Keep existing adapter-level changelog at
  `shibuya-pgmq-adapter/CHANGELOG.md` unchanged; the new top-level
  CHANGELOG is about repo-level changes.
- `mori.dhall` — new project identity `shinzui/shibuya-pgmq-adapter`,
  three packages, deps on `shinzui/shibuya`, `shinzui/pgmq-hs`,
  `hasql/hasql`, `effectful/effectful`, `composewell/streamly`,
  `iand675/hs-opentelemetry`, `Bodigrim/tasty-bench`, and two agent
  hints (`adapter-dev`, `bench-dev`, `examples-dev`). Template is
  laid out under Concrete Steps.

Finally, initialize git and register with mori:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    git init -b master
    git add .
    git commit -m "chore: initial import from shinzui/shibuya@<sha>"
    mori register --local
    # `mori/repo-id` appears — add and commit it too.
    git add mori/repo-id
    git commit -m "chore(mori): register shibuya-pgmq-adapter"

### Milestone 2: Build and test the new repository

Enter the repo and run the full build/test cycle. PostgreSQL must be
running and `PGDATABASE` reachable (the shellHook from `flake.nix`
handles initdb on first entry).

    direnv allow     # or: nix develop
    pg_ctl start -l "$PGHOST/postgres.log"
    just create-database
    cabal update
    cabal build all
    cabal test shibuya-pgmq-adapter-test
    cabal bench shibuya-pgmq-adapter-bench   # optional; slow

The test suite uses `ephemeral-pg` to spin up its own PostgreSQL, so it
does not strictly require the shellHook Postgres. Run benches only if
you want to validate the bench harness survived the move.

Acceptance: all three packages compile; test suite is green; the
endurance-test executable builds. Any failure here means something
broke in the move — stop and diagnose before milestone 3.

### Milestone 3: Remove the extracted packages from shibuya

Only proceed once milestone 2 is green.

Edit `shibuya/cabal.project`:

- Drop the three lines `shibuya-pgmq-adapter`,
  `shibuya-pgmq-adapter-bench`, `shibuya-pgmq-example`.
- Drop the four hasql `source-repository-package` stanzas (`hasql`,
  `hasql-pool`, `hasql-transaction`, `hasql-migration`).
- Keep the six hs-opentelemetry stanzas (shibuya-core still uses them).
- Keep the `allow-newer` block (proto-lens — used by shibuya-core via
  hs-opentelemetry).

Edit `shibuya/mori.dhall`:

- Remove the three `Schema.Package::{ name = "shibuya-pgmq-adapter" … }`,
  `shibuya-pgmq-adapter-bench`, `shibuya-pgmq-example` entries from the
  `packages` list.
- Remove `"shinzui/pgmq-hs"` and `"hasql/hasql"` from top-level
  `dependencies`.
- Remove the `adapter-dev` `Schema.AgentHint` (leave `framework-dev`).
- Shrink the `shibuya-full` bundle's `packages` list to
  `["shibuya-core", "shibuya-metrics"]`; keep `primary =
  "shibuya-core"`.
- Optionally add a `Schema.DocRef` pointing at the new repo for
  discoverability (not required, README link is enough).

Delete the three directories:

    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter
    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter-bench
    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-example

Rebuild and re-test:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
    cabal build all
    cabal test shibuya-core-test
    mori validate

Commit with a conventional-commits breaking message:

    chore(pgmq-adapter)!: move to shinzui/shibuya-pgmq-adapter

    The PGMQ adapter, its benchmarks, and its example application now
    live in https://github.com/shinzui/shibuya-pgmq-adapter. This decouples
    the adapter's release cadence from shibuya-core.

    ExecPlan: docs/plans/4-split-pgmq-adapter-into-own-repo.md
    Intention: intention_01kg953t69enps79pj77taz6nw

### Milestone 4: Move PGMQ documentation and update shibuya README

Move user-facing PGMQ documentation into the new repo:

    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/user/pgmq-advanced.md \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user/
    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/user/pgmq-dead-letter-queues.md \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user/
    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/user/pgmq-getting-started.md \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user/
    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/user/pgmq-topic-routing.md \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user/
    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/pgmq-adapter \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/

(Create `docs/user/` in the new repo first if absent.)

In `shibuya/README.md`:

- In the Documentation section (around line 249), remove the two
  `pgmq-*` bullet lines (`PGMQ Getting Started`, `PGMQ Advanced`).
- In the Optional packages section (around line 68), change the
  bullet for `shibuya-pgmq-adapter` to link to
  `https://github.com/shinzui/shibuya-pgmq-adapter` instead of
  Hackage-only.
- Add a new "Adapters" section just after the Features list:

        ## Adapters

        Queue backends live in sibling repositories so they can release
        on their own cadence:

        - [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter)
          — Apache Kafka via `hw-kafka-client` and `kafka-effectful`.
        - [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
          — PostgreSQL message queue (pgmq) via `pgmq-hs`.

- In the "What's New in 0.3.0.0" section, edit or annotate the first
  bullet to acknowledge that shibuya-pgmq-adapter has since moved out
  of the monorepo.

Add a CHANGELOG entry to `shibuya/CHANGELOG.md` (insert above the
existing `## 0.3.0.0 — 2026-04-24` block):

    ## Unreleased

    ### Repo Layout

    - `shibuya-pgmq-adapter`, `shibuya-pgmq-adapter-bench`, and
      `shibuya-pgmq-example` now live in their own repository at
      https://github.com/shinzui/shibuya-pgmq-adapter. They will release
      on their own cadence from this point forward. The adapter's own
      changelog continues in that repository.

### Milestone 5: Final verification

At this point, both repos should be independently buildable with
updated metadata.

Run formatters in each repo:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya && nix fmt
    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter && nix fmt

Commit the formatter fixups if any.

Validate mori:

    mori registry list | grep -E 'shinzui/shibuya($| )|shinzui/shibuya-pgmq-adapter'
    mori registry show shinzui/shibuya --full
    mori registry show shinzui/shibuya-pgmq-adapter --full
    mori validate    # in each repo

Expected: `shinzui/shibuya` shows 4 packages (core/core-bench/example/
metrics); `shinzui/shibuya-pgmq-adapter` shows 3 packages (adapter/
bench/example).

Smoke-run the example to prove the new repo works end-to-end:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    just process-up &                 # postgres via process-compose
    cabal run shibuya-pgmq-consumer   # in one shell
    cabal run shibuya-pgmq-simulator -- --queue orders --count 10  # in another

The consumer should print processed orders.


## Concrete Steps

Run all commands from the indicated working directory. Expected output
snippets are shown for key steps so the reader can tell pass from fail.

### Step 1 — Capture the source commit

Before any copying, record the shibuya commit you are splitting from;
it is used in the initial-import message of the new repo.

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
    git rev-parse HEAD

Save the SHA (example: `e426e00…`) for use in the new repo's initial
commit message.

### Step 2 — Create directory and copy packages

    mkdir -p /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/
    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter-bench \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/
    cp -a /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-example \
          /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/

Verify:

    ls /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    # expected:
    #   shibuya-pgmq-adapter
    #   shibuya-pgmq-adapter-bench
    #   shibuya-pgmq-example

### Step 3 — Write top-level `cabal.project`

Path: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/cabal.project`

    packages:
      shibuya-pgmq-adapter
      shibuya-pgmq-adapter-bench
      shibuya-pgmq-example

    -- hs-opentelemetry from GitHub (main branch for GHC 9.12 support)
    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: api

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: sdk

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: otlp

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: propagators/w3c

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: semantic-conventions

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: exporters/in-memory

    -- hasql 1.10 ecosystem (not yet on Hackage)
    source-repository-package
      type: git
      location: https://github.com/nikita-volkov/hasql
      tag: aa3d6ae499e187c291422443f221f9f486c43a9e

    source-repository-package
      type: git
      location: https://github.com/nikita-volkov/hasql-pool
      tag: 35e4c2a9d6b314fbc051e3ca31639bd83dad9f39

    source-repository-package
      type: git
      location: https://github.com/nikita-volkov/hasql-transaction
      tag: 6cb37f68bf6f5d378f15bace9d054c6d5ad99583

    source-repository-package
      type: git
      location: https://github.com/shinzui/hasql-migration
      tag: ab66f6ae93e40065f8532dd9d497ecb15c91122e

    -- Allow newer for proto-lens packages (GHC 9.12 support)
    allow-newer:
      proto-lens:base,
      proto-lens:ghc-prim,
      proto-lens-runtime:base,
      proto-lens-protobuf-types:base,
      proto-lens-protobuf-types:ghc-prim

The SHAs above are the values currently pinned in
`shibuya/cabal.project` as of the source commit. Verify with `diff` or
a manual compare; if `shibuya/cabal.project` has moved on, mirror its
current pins.

### Step 4 — Write `flake.nix`

Path: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/flake.nix`

Base this on `shibuya/flake.nix` because it already handles PostgreSQL.
The salient changes are the `description` and the `PGDATABASE` name.

    {
      description = "Shibuya adapter for pgmq (PostgreSQL message queue)";

      inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
      inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
      inputs.flake-utils.url = "github:numtide/flake-utils";
      inputs.treefmt-nix.url = "github:numtide/treefmt-nix";

      outputs = { self, nixpkgs, pre-commit-hooks, flake-utils, treefmt-nix }:
        flake-utils.lib.eachDefaultSystem (system:
          let
            pkgs = import nixpkgs { inherit system; };
            ghcVersion = "ghc912";
            treefmtEval = treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix { inherit pkgs ghcVersion; });
            formatter = treefmtEval.config.build.wrapper;
          in
          {
            formatter = formatter;
            checks = {
              formatting = treefmtEval.config.build.check self;
              pre-commit-check = pre-commit-hooks.lib.${system}.run {
                src = ./.;
                hooks = {
                  treefmt.package = formatter;
                  treefmt.enable = true;
                };
              };
            };
            devShells.default = nixpkgs.legacyPackages.${system}.mkShell {
              nativeBuildInputs = [
                pkgs.zlib
                pkgs.xz
                pkgs.just
                pkgs.cabal-install
                pkgs.haskell.packages."${ghcVersion}".haskell-language-server
                pkgs.haskell.compiler."${ghcVersion}"
                pkgs.postgresql
                pkgs.pkg-config
                pkgs.process-compose
                pkgs.jq
              ];
              shellHook = ''
                ${self.checks.${system}.pre-commit-check.shellHook}

                export PGHOST="$PWD/db"
                export PGDATA="$PGHOST/db"
                export PGLOG=$PGHOST/postgres.log
                export PGDATABASE=shibuya_pgmq_adapter

                export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

                mkdir -p $PGHOST
                mkdir -p .dev

                if [ ! -d $PGDATA ]; then
                  initdb --auth=trust --no-locale --encoding=UTF8
                fi
              '';
            };
          }
        );
    }

### Step 5 — Write `treefmt.nix`, `Justfile`, `process-compose.yaml`, `.envrc`, `.gitignore`

Path: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/treefmt.nix`
(matches shibuya's passthrough):

    { pkgs, ghcVersion, ... }:
    let
      haskellPkgs = pkgs.haskell.packages."${ghcVersion}";
    in
    {
      projectRootFile = "flake.nix";
      programs.nixpkgs-fmt.enable = true;
      programs.fourmolu.enable = true;
      programs.fourmolu.package = haskellPkgs.fourmolu;
      programs.cabal-gild.enable = true;
      programs.cabal-gild.package = haskellPkgs.cabal-gild;
    }

Path: `.../Justfile`

    default:
      just --list

    # --- Services ---
    [group("services")]
    process-up:
      process-compose --tui=false --unix-socket .dev/process-compose.sock up

    [group("services")]
    process-down:
      process-compose --unix-socket .dev/process-compose.sock down || true

    # --- Database ---
    [group("database")]
    create-database:
      psql -lqt | cut -d \| -f 1 | grep -qw $PGDATABASE || createdb $PGDATABASE

    [group("database")]
    psql:
      psql $PGDATABASE

    [group("database")]
    drop-database:
      dropdb --if-exists $PGDATABASE

    [group("database")]
    reset-database: drop-database create-database

    # --- Build ---
    [group("build")]
    build:
      cabal build all

    [group("build")]
    test:
      cabal test shibuya-pgmq-adapter-test

    [group("build")]
    bench:
      cabal bench shibuya-pgmq-adapter-bench

    [group("build")]
    example-simulator:
      cabal run shibuya-pgmq-simulator

    [group("build")]
    example-consumer:
      cabal run shibuya-pgmq-consumer

    [group("build")]
    fmt:
      nix fmt

Path: `.../process-compose.yaml` (copy shibuya's verbatim — it already
starts postgres and wires up `create_schema`):

    version: "0.5"

    log_location: ./.dev/process-compose.log
    log_level: debug

    processes:
      postgres:
        command: pg_ctl start -w -l $PGLOG -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''"
        is_daemon: true
        shutdown:
          command: pg_ctl stop -D $PGDATA
        readiness_probe:
          exec:
            command: "pg_ctl status -D $PGDATA"
          initial_delay_seconds: 2
          period_seconds: 10
          timeout_seconds: 4
          success_threshold: 1
          failure_threshold: 5
        availability:
          restart: on_failure

      create_schema:
        command: "just create-database"
        availability:
          restart: "no"
        depends_on:
          postgres:
            condition: process_healthy

Path: `.../.envrc`

    use flake
    eval "$shellHook"

Path: `.../.gitignore`

    dist
    dist-*
    dist-newstyle/
    cabal-dev

    .direnv
    .envrc

    .pre-commit-config.yaml

    cabal.project.local

    .claude/
    .config/

    # PostgreSQL dev database and process-compose
    db/
    .dev/
    CLAUDE.local.md

### Step 6 — Write `LICENSE`, `README.md`, `CHANGELOG.md`

Copy the LICENSE:

    cp /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/LICENSE \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/LICENSE

Path: `.../README.md` — model on
`shibuya-kafka-adapter/README.md`:

    # shibuya-pgmq-adapter

    PostgreSQL message queue adapter for the
    [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

    Integrates with [pgmq](https://github.com/pgmq/pgmq) via
    [`pgmq-hs`](https://github.com/shinzui/pgmq-hs). Provides visibility
    timeout-based leasing, automatic retry handling, optional dead-letter
    queue support, and OpenTelemetry tracing aligned with messaging
    semantic-conventions v1.24.

    ## Packages

    - `shibuya-pgmq-adapter` — the adapter library (`Shibuya.Adapter.Pgmq`,
      `.Config`, `.Convert`).
    - `shibuya-pgmq-adapter-bench` — `tasty-bench` micro-benchmarks covering
      send/read/ack/FIFO/multi-queue/throughput/concurrency plus a raw
      `pgmq-hasql` comparison.
    - `shibuya-pgmq-example` — runnable demo with a `shibuya-pgmq-simulator`
      and a `shibuya-pgmq-consumer` that uses multiple processors
      (orders / payments / notifications) with OpenTelemetry and Prometheus
      metrics.

    ## Building

    The repo ships a Nix flake and `direnv` config for a reproducible
    toolchain that includes PostgreSQL.

        direnv allow            # or: nix develop
        just process-up         # starts postgres + creates database
        cabal build all
        cabal test shibuya-pgmq-adapter-test

    ## Running the example

        just process-up
        cabal run shibuya-pgmq-consumer
        cabal run shibuya-pgmq-simulator -- --queue orders --count 10

    ## Layout

        shibuya-pgmq-adapter/         library sources and tests
        shibuya-pgmq-adapter-bench/   tasty-bench micro-benchmarks + endurance
        shibuya-pgmq-example/         runnable simulator + consumer
        docs/                         user docs and execution plans
        mori.dhall                    project manifest (mori registry)

    ## License

    MIT. See package `cabal` files for details.

Path: `.../CHANGELOG.md`:

    # Changelog

    ## 0.3.0.0 — 2026-04-24

    Initial release as a standalone repository. Extracted from
    `shinzui/shibuya` at commit `<SHA from Step 1>`. No user-visible API
    change relative to `shibuya-pgmq-adapter 0.3.0.0` published from the
    monorepo — this release only decouples the release cadence. See
    `shibuya-pgmq-adapter/CHANGELOG.md` for the per-package history prior
    to the split.

### Step 7 — Write `mori.dhall`

Path: `.../mori.dhall`. Template (adjust schema hash to match other
repos if `mori show --full` complains):

    let Schema =
          https://raw.githubusercontent.com/shinzui/mori-schema/9b1d6eea8027ae57576cf0712c0b9167fccbc1a9/package.dhall
            sha256:a19f5dd9181db28ba7a6a1b77b5ab8715e81aba3e2a8f296f40973003a0b4412

    let emptyRuntime = { deployable = False, exposesApi = False }

    let emptyDeps = [] : List Schema.Dependency

    let emptyDocs = [] : List Schema.DocRef.Type

    let emptyConfig = [] : List Schema.ConfigItem.Type

    in  Schema.Project::{ project =
          Schema.ProjectIdentity::{ name = "shibuya-pgmq-adapter"
          , namespace = "shinzui"
          , type = Schema.PackageType.Library
          , description = Some
              "PGMQ adapter for the Shibuya queue processing framework"
          , language = Schema.Language.Haskell
          , lifecycle = Schema.Lifecycle.Active
          , domains = [ "concurrency", "queue-processing", "postgresql" ]
          , owners = [ "shinzui" ]
          }
        , repos =
          [ Schema.Repo::{ name = "shibuya-pgmq-adapter"
            , github = Some "shinzui/shibuya-pgmq-adapter"
            , localPath = Some "."
            }
          ]
        , packages =
          [ Schema.Package::{ name = "shibuya-pgmq-adapter"
            , type = Schema.PackageType.Library
            , language = Schema.Language.Haskell
            , path = Some "shibuya-pgmq-adapter"
            , description = Some
                "PGMQ adapter with visibility timeout leasing, retry handling, and DLQ support"
            , runtime = emptyRuntime
            , dependencies =
              [ Schema.Dependency.ByName "effectful/effectful"
              , Schema.Dependency.ByName "shinzui/pgmq-hs"
              , Schema.Dependency.ByName "hasql/hasql"
              , Schema.Dependency.ByName "shinzui/shibuya"
              , Schema.Dependency.ByName "composewell/streamly"
              ]
            , docs = emptyDocs
            , config = emptyConfig
            }
          , Schema.Package::{ name = "shibuya-pgmq-adapter-bench"
            , type = Schema.PackageType.Other "Benchmark"
            , language = Schema.Language.Haskell
            , path = Some "shibuya-pgmq-adapter-bench"
            , description = Some
                "Throughput and concurrency benchmarks for the PGMQ adapter"
            , visibility = Schema.Visibility.Internal
            , runtime = emptyRuntime
            , dependencies =
              [ Schema.Dependency.ByName "Bodigrim/tasty-bench"
              ]
            , docs = emptyDocs
            , config = emptyConfig
            }
          , Schema.Package::{ name = "shibuya-pgmq-example"
            , type = Schema.PackageType.Application
            , language = Schema.Language.Haskell
            , path = Some "shibuya-pgmq-example"
            , description = Some
                "Runnable example with PGMQ, OpenTelemetry tracing, and Prometheus metrics"
            , visibility = Schema.Visibility.Internal
            , runtime = { deployable = True, exposesApi = True }
            , dependencies = emptyDeps
            , docs = emptyDocs
            , config = emptyConfig
            }
          ]
        , dependencies =
          [ "shinzui/shibuya"
          , "effectful/effectful"
          , "composewell/streamly"
          , "shinzui/pgmq-hs"
          , "hasql/hasql"
          , "iand675/hs-opentelemetry"
          , "Bodigrim/tasty-bench"
          ]
        , agents =
          [ Schema.AgentHint::{ role = "adapter-dev"
            , description = Some
                "PGMQ adapter development: leasing, retries, DLQ, tracing"
            , includePaths =
              [ "shibuya-pgmq-adapter/src/**"
              , "shibuya-pgmq-adapter/test/**"
              ]
            , excludePaths =
              [ "dist-newstyle/**"
              ]
            , relatedPackages =
              [ "shibuya-pgmq-adapter"
              ]
            }
          , Schema.AgentHint::{ role = "bench-dev"
            , description = Some
                "Benchmark development: tasty-bench suites and endurance harness"
            , includePaths =
              [ "shibuya-pgmq-adapter-bench/**"
              ]
            , excludePaths =
              [ "dist-newstyle/**"
              ]
            , relatedPackages =
              [ "shibuya-pgmq-adapter-bench"
              ]
            }
          , Schema.AgentHint::{ role = "examples-dev"
            , description = Some
                "Example app development: simulator + consumer"
            , includePaths =
              [ "shibuya-pgmq-example/**"
              ]
            , excludePaths =
              [ "dist-newstyle/**"
              ]
            , relatedPackages =
              [ "shibuya-pgmq-example"
              ]
            }
          ]
        , docs =
          [ Schema.DocRef::{ key = "readme"
            , kind = Schema.DocKind.Guide
            , audience = Schema.DocAudience.User
            , description = Some "Project README with quickstart"
            , location = Schema.DocLocation.LocalFile "README.md"
            }
          , Schema.DocRef::{ key = "changelog"
            , kind = Schema.DocKind.Notes
            , audience = Schema.DocAudience.User
            , description = Some "Release changelog"
            , location = Schema.DocLocation.LocalFile "CHANGELOG.md"
            }
          , Schema.DocRef::{ key = "plans"
            , kind = Schema.DocKind.Reference
            , audience = Schema.DocAudience.Internal
            , description = Some "Execution plans for adapter development"
            , location = Schema.DocLocation.LocalDir "docs/plans"
            }
          , Schema.DocRef::{ key = "hackage"
            , kind = Schema.DocKind.Reference
            , audience = Schema.DocAudience.API
            , description = Some "Hackage package page"
            , location =
                Schema.DocLocation.Url
                  "https://hackage.haskell.org/package/shibuya-pgmq-adapter"
            }
          ]
        }

### Step 8 — Git init and mori register

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    git init -b master
    git add .
    git commit -m "chore: initial import from shinzui/shibuya@<SHA>"
    mori validate          # expect: "OK" or equivalent
    mori register --local  # expect: "registered shinzui/shibuya-pgmq-adapter"
    ls mori/               # expect: repo-id
    git add mori/repo-id
    git commit -m "chore(mori): register shibuya-pgmq-adapter"

    mori registry show shinzui/shibuya-pgmq-adapter --full
    # expect: 3 packages, path matches this directory

### Step 9 — Build + test the new repo

From inside the `direnv`-allowed shell:

    just process-up        # background postgres + create database
    cabal update
    cabal build all
    cabal test shibuya-pgmq-adapter-test

Expected: build succeeds; `hspec` runs all specs green. The
integration spec uses `ephemeral-pg` so it starts its own Postgres
instance on ports 5433+. If `ephemeral-pg` cannot find `initdb` on
PATH, re-enter the nix devShell — `pkgs.postgresql` in
`nativeBuildInputs` puts it there.

### Step 10 — Shrink shibuya's `cabal.project`

Path: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/cabal.project`.

The result should look exactly like:

    packages:
      shibuya-core
      shibuya-core-bench
      shibuya-example
      shibuya-metrics

    -- hs-opentelemetry from GitHub (main branch for GHC 9.12 support)
    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: api

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: sdk

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: otlp

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: propagators/w3c

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: semantic-conventions

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: exporters/in-memory

    -- Allow newer for proto-lens packages (GHC 9.12 support)
    allow-newer:
      proto-lens:base,
      proto-lens:ghc-prim,
      proto-lens-runtime:base,
      proto-lens-protobuf-types:base,
      proto-lens-protobuf-types:ghc-prim

(Four hasql `source-repository-package` stanzas removed; three package
lines removed.)

### Step 11 — Shrink shibuya's `mori.dhall`

Edit `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/mori.dhall`:

- In `packages`, remove the three `Schema.Package::{ name =
  "shibuya-pgmq-adapter" … }`, `shibuya-pgmq-adapter-bench`, and
  `shibuya-pgmq-example` entries.
- In top-level `dependencies`, remove `"shinzui/pgmq-hs"` and
  `"hasql/hasql"`.
- Remove the `Schema.AgentHint::{ role = "adapter-dev" … }` hint.
- Change `bundles[0].packages` from `["shibuya-core", "shibuya-metrics",
  "shibuya-pgmq-adapter"]` to `["shibuya-core", "shibuya-metrics"]`.

Validate:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
    mori validate
    mori registry show shinzui/shibuya --full
    # expect: 4 packages, no pgmq packages, no adapter-dev hint

### Step 12 — Delete and rebuild shibuya

    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter
    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-adapter-bench
    rm -rf /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-pgmq-example

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
    cabal build all
    cabal test shibuya-core-test

Expected: clean build, test suite green.

### Step 13 — Move PGMQ docs

    mkdir -p /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user

    git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya \
      mv docs/user/pgmq-advanced.md        \
         docs/user/pgmq-dead-letter-queues.md \
         docs/user/pgmq-getting-started.md \
         docs/user/pgmq-topic-routing.md   \
         /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/user/

(Plain `mv` between repos is fine since we are not preserving per-file
git history; the subsequent `git add -A` in each repo captures the
right diff.)

    mv /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/pgmq-adapter \
       /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/docs/pgmq-adapter

### Step 14 — Update shibuya's README and CHANGELOG

Apply the edits described in Milestone 4.

### Step 15 — Commit and verify

In shibuya:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
    nix fmt
    git add -A
    git commit -m "$(cat <<'EOF'
    chore(pgmq-adapter)!: split into shinzui/shibuya-pgmq-adapter

    Move shibuya-pgmq-adapter, shibuya-pgmq-adapter-bench, and
    shibuya-pgmq-example into their own repository. This decouples the
    adapter's release cadence from shibuya-core.

    Also removes the hasql 1.10 source-repository-package entries from
    cabal.project (no longer needed by the remaining packages) and shrinks
    mori.dhall accordingly. PGMQ user docs now live alongside the adapter.

    ExecPlan: docs/plans/4-split-pgmq-adapter-into-own-repo.md
    Intention: intention_01kg953t69enps79pj77taz6nw
    EOF
    )"

In the new repo:

    cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
    nix fmt
    git add -A
    git commit -m "$(cat <<'EOF'
    docs: import PGMQ user guides from shinzui/shibuya

    ExecPlan: docs/plans/4-split-pgmq-adapter-into-own-repo.md
    Intention: intention_01kg953t69enps79pj77taz6nw
    EOF
    )"

(Note: this commit's `ExecPlan:` trailer points at the plan path in
`shibuya`. That is intentional — the plan itself does not move.)


## Validation and Acceptance

After Milestone 5, validate each of the following and record results in
the Progress section or Surprises & Discoveries.

1. **New repo builds and tests.** In
   `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`:

        cabal build all
        cabal test shibuya-pgmq-adapter-test

   Expected: build succeeds; hspec prints a summary like
   `xx examples, 0 failures`.

2. **Shibuya still builds and tests.** In
   `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

        cabal build all
        cabal test shibuya-core-test

   Expected: build succeeds (no more attempts to resolve `pgmq-*` or
   `hasql-*` source-repository-packages), test suite green.

3. **Mori registry reflects the new topology.**

        mori registry list | grep -E 'shibuya($| )|shibuya-pgmq-adapter'

   Expected: two `own` rows, one per repo.

        mori registry show shinzui/shibuya --full
        # expect: 4 packages (no pgmq*)
        mori registry show shinzui/shibuya-pgmq-adapter --full
        # expect: 3 packages (adapter/bench/example)

4. **End-to-end smoke test of the example.** In
   `shibuya-pgmq-adapter` with `direnv` allowed and postgres running:

        cabal run shibuya-pgmq-consumer &
        cabal run shibuya-pgmq-simulator -- --queue orders --count 10

   Expected: consumer logs show ten orders processed; no retries other
   than the 10% intentional simulation documented in
   `shibuya-pgmq-example/README.md`.

5. **Formatting and pre-commit hooks pass in both repos.**

        nix flake check

   in each repo returns no formatting diffs.


## Idempotence and Recovery

All steps are idempotent in the following sense:

- `cp -a` may be re-run; the destination is the new repo and is empty
  before milestone 1. If a partial copy exists, remove the new repo
  and restart.
- Edits to `cabal.project`, `mori.dhall`, `README.md`, and
  `CHANGELOG.md` are straight content edits — re-opening and matching
  the target state described here gets you back on track regardless of
  how you arrived.
- `mori register --local` is safe to re-run; it rewrites the registry
  entry in place.
- `rm -rf` of the three package dirs in `shibuya` (Milestone 3) is the
  only destructive step. Mitigation: milestone 2 must complete
  successfully before milestone 3 starts, so the new repo already
  contains the only authoritative copy. Secondary mitigation: the
  `shibuya` working tree is a git repository, so the deletion can be
  recovered via `git restore` or `git checkout HEAD --` until the
  commit in Step 15 seals it — even then, `git show HEAD^:path` can
  restore individual files.

Rollback path if Milestone 2 fails catastrophically and the split is
abandoned: discard the new repo directory entirely (`rm -rf
/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`),
revert mori registration with `mori registry unregister shinzui/shibuya-pgmq-adapter`
(consult `mori registry --help`), and leave `shibuya` untouched. No
data loss because no shibuya changes have happened yet.

Rollback if Milestone 3 fails (shibuya build breaks after package
removal): `git reset --hard HEAD~1` in shibuya to restore the three
package directories and the `cabal.project`/`mori.dhall` edits, then
diagnose before retrying.


## Interfaces and Dependencies

The plan does not define new Haskell interfaces. It reorganizes
packaging metadata so that the existing interfaces continue to work.

### Preserved Haskell interfaces

These modules and their exports must remain unchanged across the move
(same content, same module names):

- In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` —
  `Shibuya.Adapter.Pgmq` (public entry point).
- In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` —
  `Shibuya.Adapter.Pgmq.Config`.
- In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` —
  `Shibuya.Adapter.Pgmq.Convert`.
- Internal: `Shibuya.Adapter.Pgmq.Internal` (listed in
  `other-modules`).

The `shibuya-pgmq-adapter.cabal` `build-depends` on `shibuya-core
^>=0.3.0.0` stays unchanged. Once the new repo's CI publishes, it will
resolve `shibuya-core` from Hackage.

### Dependency graph after the split

    shinzui/shibuya
      ├── shibuya-core            (library)
      ├── shibuya-core-bench      (benchmark)
      ├── shibuya-example         (app, mock adapter)
      └── shibuya-metrics         (library)

    shinzui/shibuya-pgmq-adapter
      ├── shibuya-pgmq-adapter        (library)  depends on:
      │      shibuya-core, pgmq-core, pgmq-effectful, pgmq-hasql,
      │      effectful-core, streamly, ...
      ├── shibuya-pgmq-adapter-bench  (benchmark) depends on:
      │      shibuya-pgmq-adapter, shibuya-core, pgmq-migration,
      │      tasty-bench, ...
      └── shibuya-pgmq-example        (app) depends on:
             shibuya-pgmq-adapter, shibuya-core, shibuya-metrics,
             hs-opentelemetry-*, pgmq-migration, ...

Mori-level dependency declarations after the split:

    shinzui/shibuya.dependencies:
      effectful/effectful, composewell/streamly

    shinzui/shibuya-pgmq-adapter.dependencies:
      shinzui/shibuya, effectful/effectful, composewell/streamly,
      shinzui/pgmq-hs, hasql/hasql, iand675/hs-opentelemetry,
      Bodigrim/tasty-bench

### External services required for tests

- PostgreSQL with the `pgmq` extension reachable on a Unix socket. The
  `flake.nix` shellHook + `process-compose.yaml` provide this locally.
- Optional: Jaeger at `http://127.0.0.1:4318` for tracing smoke tests.
  `shibuya/docker-compose.otel.yaml` can be adapted later; not part of
  this plan's acceptance.
