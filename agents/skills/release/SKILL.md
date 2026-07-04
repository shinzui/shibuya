---
name: release
description: Release all packages to Hackage following PVP
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Multi-Package Release Skill

Release all packages from this multi-package repository to Hackage using a single shared version.

## Versioning Strategy

All packages share the **same version number** and are released together. A single git tag `v<version>` marks each release.

## Packages (in dependency order)

The packages MUST be published in this order due to inter-package dependencies:

1. **shibuya-core** — core framework (no internal deps)
2. **shibuya-metrics** — metrics web server (depends on shibuya-core)

The following packages are **NOT released** to Hackage:
- **shibuya-example** (example app)
- **shibuya-core-bench** (benchmark suite)

> **Note:** `shibuya-pgmq-adapter`, `shibuya-pgmq-example`, and
> `shibuya-pgmq-adapter-bench` were split out into the
> [`shinzui/shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter)
> repository as of 2026-04 (commit 5a66aa1). They release on their own
> cadence from that repo.

## Arguments

`$ARGUMENTS` is optional:
- `major`, `minor`, or `patch` — specifies the bump level
- If omitted, determine the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from any package's `.cabal` file (they all share the same version).
- Find the latest git tag matching `v*` to identify the last release point.
- Run `git log --oneline <last-tag>..HEAD` to list commits since the last release.
- If there are no commits since the last tag, inform the user there is nothing to release and stop.

Present a summary showing:
- Current version
- Last release tag (or "none")
- Number of commits since last release
- Which package directories have changes

### 2. Determine the next version using PVP

The Haskell PVP version format is `A.B.C.D`:
- `A.B` is the **major** version — bump for breaking API changes (removed/renamed exports, changed types, changed semantics)
- `C` is the **minor** version — bump for backwards-compatible API additions (new exports, new modules, new type class instances)
- `D` is the **patch** version — bump for bug fixes, documentation, internal-only changes, performance improvements

Rules:
- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise, analyze the commits to determine the appropriate bump:
  - Look for keywords like "breaking", "remove", "rename", "change type" → major
  - Look for keywords like "add", "new", "feature", "export" → minor
  - Look for keywords like "fix", "suppress", "docs", "refactor", "internal" → patch
- Present the proposed bump to the user and ask for confirmation before proceeding.

Increment the version:
- **major**: increment `B`, reset `C` and `D` to 0 (e.g., `0.2.0.1` → `0.3.0.0`)
- **minor**: increment `C`, reset `D` to 0 (e.g., `0.2.0.1` → `0.2.1.0`)
- **patch**: increment `D` (e.g., `0.2.0.1` → `0.2.0.2`)

### 3. Update versions and changelogs

#### Version update
- Edit both package cabal files to set the new version:
  - `shibuya-core/shibuya-core.cabal`
  - `shibuya-metrics/shibuya-metrics.cabal`
- Note: a `shibuya-core` cabal version may already have been bumped mid-cycle (e.g. so an external consumer can declare the new lower bound). In that case only `shibuya-metrics`'s cabal version still needs bumping at release time, but verify both are at the target version before committing.

#### Dependency bounds update
- Update the `shibuya-core` dependency bound in `shibuya-metrics/shibuya-metrics.cabal` (both the library and test-suite sections, if a test-suite exists).
- Use PVP-compatible bounds: `shibuya-core ^>=A.B.C.D` matching the new version.

#### Changelog update
- For each package that has a `CHANGELOG.md`, add a new section for the new version above any previous entries. Use today's date in `YYYY-MM-DD` format.
- If a package does not yet have a `CHANGELOG.md`, create one with a header and the new version section.
- Move content from "Unreleased" section (if any) into the new version section.
- Summarize commits since last release, grouped by:
  - **Breaking Changes** (if major)
  - **New Features** (if minor or major)
  - **Bug Fixes** (if any)
  - **Other Changes** (docs, refactoring, etc.)
  - Only include categories that have entries.
- Also update the root `CHANGELOG.md` (create it if it does not exist).

Show the user ALL changes (version bumps, dependency bounds, changelog entries) for review before committing.

### 4. Verify builds

- Run `nix fmt` to ensure code is properly formatted.
- Run `cabal build all` to verify cabal build succeeds.
- Run `cabal test shibuya-core-test` to confirm tests pass before publishing.
- Run `nix flake check` to verify treefmt and pre-commit checks pass.
  - The flake currently exposes only `checks` / `devShells` / `formatter` (no `packages.default`), so `nix flake check` is the appropriate gate; `nix build` will fail with "does not provide attribute packages.<system>.default".
  - Note: newly created files must be `git add`-ed before nix evaluation will see them, since nix uses the git tree.
  - If any check fails, fix the issue before proceeding.

### 5. Check for performance regressions (non-patch releases only)

**Skip this step for `patch` (bug-fix) releases.** For `minor` and `major` releases, run the benchmark suite and compare against the previous release to catch performance/allocation regressions before publishing. This guards the ~4x-vs-streamly overhead and per-message allocation budget that EP-30/EP-31 established.

The benchmark package is `shibuya-core-bench` (not released to Hackage; uses [tasty-bench](https://hackage.haskell.org/package/tasty-bench), which supports CSV baselines and `--fail-if-slower`). See `shibuya-core-bench/README.md` for full details.

Procedure:

1. **Capture a baseline from the previous release tag.** Use a detached git worktree so the working tree (with the pending version/changelog edits) stays untouched:

   ```bash
   git worktree add /tmp/shibuya-bench-baseline <last-tag>
   cabal bench shibuya-core-bench \
     --project-dir /tmp/shibuya-bench-baseline \
     --benchmark-options="--csv /tmp/shibuya-baseline.csv --stdev 5 --timeout 120"
   ```

   (If `--project-dir` is not usable in this setup, `cd /tmp/shibuya-bench-baseline` and run `cabal bench` there instead. Prefer a worktree over `git stash`/checkout so uncommitted release edits are never disturbed.)

2. **Run the current tree against that baseline** with a failure threshold. tasty-bench fails the run if any benchmark is slower than the threshold percent:

   ```bash
   cabal bench shibuya-core-bench \
     --benchmark-options="--baseline /tmp/shibuya-baseline.csv --fail-if-slower 10 --stdev 5 --timeout 120"
   ```

3. **Interpret the results:**
   - A non-zero exit / any benchmark flagged slower than the threshold is a **regression**. Also inspect the `allocated` column — an allocation increase (even if time is within noise) is a regression per EP-30/EP-31 and must be explained.
   - The `--fail-if-slower 10` gate is deliberately tight. With `--stdev 5` the measurement noise floor is roughly ±5%, so a single borderline result (just over 10%) may still be noise. Re-run with a tighter `--stdev` (e.g. `3`) and/or larger `--timeout` before concluding. Machine load matters — close other apps.
   - If a genuine regression is found, **stop and report it to the user** with the before/after numbers. Do not proceed to release until the user either accepts the regression (e.g. an intentional trade-off, which should be noted in the changelog) or the regression is fixed.

4. **Clean up the worktree** when done:

   ```bash
   git worktree remove /tmp/shibuya-bench-baseline
   ```

If there is no previous release tag (first release), note that no baseline comparison is possible and just record the current numbers for future comparison.

### 6. Commit, tag, and push

- Stage all modified `.cabal` and `CHANGELOG.md` files.
- Create a single commit using a Conventional Commits message: `chore(release): <new-version>` (project-wide convention — see global CLAUDE.md). The body should summarize what's in the release and why this is the chosen bump.
- Create a single annotated git tag: `git tag -a v<version> -m "Release <version>"`
- Push the commit and tag: `git push && git push --tags`

### 7. Publish to Hackage (in dependency order)

For EACH package, in dependency order (shibuya-core → shibuya-metrics):

1. `cd <pkg-dir>`
2. Run `cabal check` to verify no packaging issues.
3. Run `cabal test <pkg>` to ensure tests pass (skip for packages without test suites).
4. Run `cabal sdist` and then `cabal upload --publish <tarball-path>` to publish the source distribution.
5. Run `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump` and then `cabal upload --publish --documentation <docs-tarball-path>` to publish documentation.
6. Report the Hackage URL for each package.

The Hackage URLs follow the pattern: `https://hackage.haskell.org/package/<pkg>-<version>`

After all packages are published, present a summary:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| shibuya-core | X.Y.Z.W | https://hackage.haskell.org/package/shibuya-core-X.Y.Z.W |
| shibuya-metrics | X.Y.Z.W | https://hackage.haskell.org/package/shibuya-metrics-X.Y.Z.W |

### 8. Create GitHub release

After all Hackage uploads succeed, create a GitHub release for the tag:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| shibuya-core | https://hackage.haskell.org/package/shibuya-core-X.Y.Z.W |
| shibuya-metrics | https://hackage.haskell.org/package/shibuya-metrics-X.Y.Z.W |

## What's Changed

<changelog entries for this version from the root CHANGELOG.md>
EOF
)"
```

- Use the root `CHANGELOG.md` entries for the release notes body.
- Include the Hackage links table so each package is easily discoverable.
- Report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and changelogs before committing.
- Always publish in dependency order: shibuya-core → shibuya-metrics.
- Never skip `cabal check`, tests, or `nix flake check`.
- For `minor` and `major` releases, never skip the benchmark regression check (step 5). If a genuine regression is found, stop and get the user's decision before releasing. It is only skipped for `patch` (bug-fix) releases.
- If any step fails (including `nix flake check`), stop and report the error rather than continuing.
- If a Hackage upload fails for a package, do NOT continue uploading subsequent packages that depend on it.
- Run `nix fmt` before committing to ensure proper formatting.
- The commit and tag should only be created AFTER user approval of all changes.
