# EP-39 metrics lifecycle evidence

This directory retains EP-39's focused performance measurements, negative controls, final
package runs, and implementation identities. The corresponding acceptance decisions are
recorded in
`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`.

## Identity

- Activity baseline source: `682003e7e20bcbf49a5a6e1295fc9efdc6677395`
- Accepted activity candidate source: `82a8e90f02b5c52a291a4655ee34c604d8fdb2e9`
- WebSocket baseline source: `98bbede929f31326b9ca488bbfa56f3f6d6a3b77`
- WebSocket lifecycle candidate source: `75d99fc49ac84509fe41f91f52bd4167487fda5d`
- Final implementation candidate source: `6535a036827c0bdfa1dd8c8a3ca9d228776f3f51`
- Compiler: GHC 9.12.4, optimization profile `-O1` library / `-O2` benchmark
- Solver plan SHA-256: `c099947407a29e3f2c2d6508067369c53593d6ac5e3a6584cda33d168324b53b`
- Machine: `MacBookPro18,2`, Darwin 25.6.0 arm64, 10 logical CPUs
- RTS: `-N1`, benchmark arena `-A32m`

## Performance

The activity baseline was built in a detached worktree and measured with:

```bash
cabal bench shibuya-core-bench --benchmark-options='-p hot-path --stdev 3 --timeout 120 --csv /tmp/ep39-hotpath-baseline.csv +RTS -N1 -RTS'
```

The rejected direct-clock candidate and accepted sampler candidate used:

```bash
cabal bench shibuya-core-bench --benchmark-options='-p hot-path --stdev 3 --timeout 120 --baseline /tmp/ep39-hotpath-baseline.csv --fail-if-slower 5 --csv <candidate.csv> +RTS -N1 -RTS'
```

`direct-clock-candidate.csv` failed both cells: serial was reported 28% slower and
async8 12% slower. `sampler-candidate.csv` passed both 5% comparisons and retained
the baseline allocation class. CSV means and two-standard-deviation estimates are
the raw tasty-bench outputs, not a substitute for EP-45's final paired candidate
matrix.

The final WebSocket candidate was compared with the pre-WebSocket baseline using the exact
real-socket Hspec case `sends an initial snapshot`:

```bash
hyperfine --prepare 'sleep 0.1' --warmup 5 --runs 30 \
  --export-json websocket-snapshot-hyperfine.json \
  --command-name baseline-websocket-snapshot '<baseline-test-binary> --match "sends an initial snapshot" --seed 1' \
  --command-name candidate-websocket-snapshot '<candidate-test-binary> --match "sends an initial snapshot" --seed 1'
```

The unmeasured 100 ms preparation interval isolates successive ephemeral-server runs. The
baseline mean was 26.251 ms (standard deviation 1.134 ms); the candidate mean was 25.208 ms
(standard deviation 1.516 ms), 3.97% faster and therefore inside the inherited 5% focused
time budget. An initial rapid-repetition attempt without the settle interval exposed the
baseline defect itself: iteration 10 failed with uncaught `ConnectionClosed`; the diagnostic
is retained in `websocket-snapshot-baseline-instability.log`. This narrow developer signal
does not replace EP-45's final alternating N1/N4 matrix.

## Correctness

An isolated worktree at the activity baseline ran five added health regressions. All five
failed: separated bursts and sustained progress were falsely stuck, an unregistered configured
failure became ready, a stopped master remained live, and a hung dependency outlived the outer
test bound. The accepted activity candidate ran 36 metrics examples, 236 ordinary core examples,
and both isolated core GC suites with zero failures.

At the Milestone 2 evidence commit, an isolated WebSocket worktree at the WebSocket baseline
failed disabled-upgrade, subscribe-all exclusion, and disconnect cleanup regressions in an
11-example run (seed `719269874`). A second isolated test injected failure while building the
initial snapshot; the baseline retained the only connection slot beyond the one-second STM
barrier (seed `1370922219`). The WebSocket candidate passed those regressions plus real
`goodbye` and bounded terminal-failure delivery in the full 44-example metrics suite.
`cabal build all` also exited zero.

Milestone 4 added dependency exception normalization. At baseline
`686bfe2c50d028f1387c2cd7f4c6b503a64f1bd9`, the real endpoint regression escaped
`user error (database exploded)` instead of returning HTTP 503 (seed `2048864257`). The
final candidate converts synchronous dependency exceptions to unhealthy status while
preserving asynchronous cancellation and the configured timeout.

The final run in `cabal-test-shibuya-metrics.log` passed 48 examples. The run in
`cabal-test-shibuya-core.log` passed 236 ordinary examples plus `shibuya-core-gc-test` and
`shibuya-core-gc-finished-test`. Relative to the Milestone 1 contract commit
`4d590346ff21f2d8b4dfa992d963e65995e2f013`, the only golden difference is the recorded
additive JSON field `lastProgress`; the Prometheus golden is unchanged. Both edited OKF
bundles pass profile and log enforcement. These are focused child-plan checks; EP-45 owns
the final paired candidate matrix and EP-44 owns integrated certification.
