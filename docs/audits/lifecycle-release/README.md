# Lifecycle release evidence

This directory is the shared evidence contract for the lifecycle remediation initiative.
`findings.json` is the mutable inventory: remediation children update their owned findings
and boundary cells as evidence becomes available. Historical records under `docs/reviews/`
remain unchanged. `coverage.md` defines the vocabulary and ownership rules, while
`scripts/audit/validate-evidence.ts` enforces them.

The validator has two modes. Inventory mode proves that the ledger is internally complete
and may succeed while findings are still open. Release mode proves that one exact candidate
has no unresolved safety work and that all mandatory matrix evidence matches that candidate.
Both modes always print out-of-scope findings so exclusions cannot disappear from the final
verdict.

## Append-only layout

Create one manifest at `docs/audits/lifecycle-release/candidates/<candidate-id>.json` and put
run artifacts under `docs/audits/lifecycle-release/artifacts/<candidate-id>/<run-id>/`. Once
any evidence run refers to a candidate ID, do not replace that manifest or reuse the run ID.
A source, package, dependency solution, compiler, platform, or service change creates a new
candidate ID and new runs. This is append-only at the candidate/run level; old failed and
inconclusive evidence remains available for audit.

The checked-in `candidates/example-incomplete.json` is intentionally not a candidate for
release. It identifies the 0.9.0.3 core/metrics baseline and the adapter revisions reviewed by
REV-10, REV-11, and REV-13, but contains no finding results, matrix runs, services, or test
artifacts. It demonstrates the failure mode and must continue to exit nonzero.

Every real manifest records:

- one `projects` entry for each included package component, with a full Git SHA, a clean-tree
  assertion, and exact package versions;
- the SHA-256 of the unified Cabal solver plan, compiler, platform, service versions, and
  manifest timestamp;
- every command with start and finish timestamps and exit code;
- an `evidenceRuns` record whose complete source-SHA map and solver-plan hash match the
  candidate, plus an explicit seed or `null` and repository-relative artifact paths;
- one candidate-bound result for every in-scope inventory entry and one passing run for every
  mandatory lifecycle matrix cell; and
- any human-approved waiver with approver kind `human`, name, rationale, expiry, affected
  release scope, and compensating controls.

Diagnostic work may record a dirty patch hash beside a project, but release evidence requires
`clean: true` and committed source. Store the exact command transcript, machine-readable test
report, service log, and measurement file under the run directory. A summary without the raw
artifact is not evidence.

## Execution budgets

Set budgets before running remediation or candidate comparisons. Each deterministic
concurrency regression runs 100 repetitions. Each reference-model or property workload runs
1,000 cases from a recorded seed. Core lifecycle scenarios run under both single-capability
and multi-capability RTS settings. Kafka, PGMQ, and Kiroku each receive a bounded 30-minute
soak at the adapter's documented supported concurrency, using uniquely named ephemeral
resources and preserving logs from failures.

The starting performance limits are no more than 5% throughput loss, 10% tail-latency or
shutdown-latency increase, and 5% allocation or live-memory increase, using paired runs and
confidence bounds. EP-45 calibrates separate absolute idle CPU and memory budgets before the
candidate run. Existing stricter budgets win. Inconclusive results fail. No throughput gain
can compensate for data loss, a hang, an orphaned worker, sustained memory growth, or a
missing lifecycle matrix cell.

Changing an execution or performance budget after observation requires a named human release
owner, the reason, the affected release scope, and the revised value. Record that decision in
the candidate and the owning plan. An agent never waives its own failed gate.

## Local and eventual CI commands

Run from the Shibuya repository root. The same commands are the eventual CI entry points; CI
may add artifact upload and service setup, but it must not use a different validator or weaker
selectors.

```bash
bun test scripts/audit/validate-evidence.test.ts
bun scripts/audit/validate-evidence.ts \
  --inventory docs/audits/lifecycle-release/findings.json
bun scripts/audit/validate-evidence.ts \
  --release docs/audits/lifecycle-release/candidates/<candidate-id>.json
```

Inventory success reports finding, boundary, mandatory-cell, and exclusion counts. Release
success additionally means all candidate-bound results and mandatory cells passed. A release
command that reports no tests, skips a required service, or lacks raw artifacts is not a
passing run even if its shell exit status is zero.

Demonstrate the negative control with:

```bash
bun scripts/audit/validate-evidence.ts \
  --release docs/audits/lifecycle-release/candidates/example-incomplete.json
```

That command exits 1, prints all five MessageDB entries as `UNCERTIFIED`, and names the open
findings and missing candidate-bound results and matrix runs. If it exits zero, the release
gate is broken.

## Child-plan workflow

An owning remediation child first adds failing evidence or records why a source concern is
disproved, then commits its fix and passing regression. It updates every applicable
review-derived finding, even when one fix closes several entries, and changes boundary cells
to `passed` only with repository-relative artifact paths. Adapter evidence uses the canonical
component identities in the inventory: `mori://shinzui/shibuya-kafka-adapter`,
`mori://shinzui/shibuya-pgmq-adapter`, and `mori://shinzui/kiroku` remain the owning projects.

EP-44 creates the final clean candidate manifest and runs release validation. It does not
edit historical evidence to make a candidate pass. A changed source SHA or solver-plan hash
invalidates every earlier evidence run automatically, so EP-44 creates a new candidate and
reruns the affected cells.
