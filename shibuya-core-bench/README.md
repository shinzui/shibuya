# shibuya-core-bench

Benchmarks for measuring shibuya-core framework overhead using [tasty-bench](https://hackage.haskell.org/package/tasty-bench).

## Purpose

This benchmark suite measures the overhead of the shibuya framework compared to using pure streamly. The goal is to ensure that framework overhead remains minimal, allowing applications to achieve near-streamly performance.

Key questions this benchmark answers:
- How much overhead does shibuya add vs raw streamly?
- What is the per-message cost of the supervision infrastructure?
- How do different handler patterns affect performance?
- What is the memory footprint of the framework?

## Quick Start

```bash
# Run all benchmarks with default settings
cabal bench shibuya-core-bench

# Quick run with relaxed precision (faster, less accurate)
cabal bench shibuya-core-bench --benchmark-options="--stdev 50 --timeout 30"

# Full precision run (slower, more accurate)
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 120"
```

## Running Benchmarks

### Controlled lifecycle workloads

EP-45 adds `lifecycle-load`, which drives the production `runSupervised` and
`runSupervisedBatch` paths through bounded-inbox, partitioned, batching, retry,
dead-letter, idle, observer and repeated-start/stop scenarios. Unlike tasty-bench, it runs
one scenario once and prints JSON with end-to-end acknowledgement latency, throughput,
allocation, live-heap, CPU, GC and shutdown measurements plus expected/completed/acknowledged
counts.

```bash
cabal run shibuya-core-bench:lifecycle-load -- --list
cabal run shibuya-core-bench:lifecycle-load -- \
  --scenario serial-small-inbox \
  --sample-id baseline-n1-01 \
  +RTS -N1 -T -RTS
cabal run shibuya-core-bench:lifecycle-load -- \
  --scenario async-hot-key \
  --sample-id baseline-n4-01 \
  +RTS -N4 -T -RTS
```

Run every measured sample in a fresh process. `maxLiveBytes` is a process high-water mark,
so combining scenarios would contaminate later samples. The health and WebSocket proxy
scenarios measure internal snapshot pressure and are labeled as proxies in JSON; they are not
substitutes for the live protocol fixtures owned by EP-39.

### Basic Commands

```bash
# Run all benchmarks
cabal bench shibuya-core-bench

# Run with memory statistics (enabled by default via -T RTS option)
cabal bench shibuya-core-bench

# Run specific benchmark patterns
cabal bench shibuya-core-bench --benchmark-options="-p baseline"
cabal bench shibuya-core-bench --benchmark-options="-p framework"
cabal bench shibuya-core-bench --benchmark-options="-p handler"
cabal bench shibuya-core-bench --benchmark-options="-p dead-letter-reason"

# Run a specific sub-benchmark
cabal bench shibuya-core-bench --benchmark-options="-p comparison"
```

### Tuning Parameters

```bash
# Set timeout for individual benchmarks (seconds)
cabal bench shibuya-core-bench --benchmark-options="--timeout 60"

# Set target standard deviation (lower = more precise, slower)
cabal bench shibuya-core-bench --benchmark-options="--stdev 10"

# Combine options for quick development iteration
cabal bench shibuya-core-bench --benchmark-options="-p framework --stdev 50 --timeout 30"

# Production-quality benchmark run
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 300"
```

### Saving and Comparing Results

```bash
# Save baseline results to CSV
cabal bench shibuya-core-bench --benchmark-options="--csv baseline.csv"

# Compare against saved baseline
cabal bench shibuya-core-bench --benchmark-options="--baseline baseline.csv"
```

## Benchmark Categories

### Baseline (Pure Streamly)

Establishes the performance floor using pure streamly operations:
- **stream-creation**: Creating streams of messages (fromList)
- **stream-consumption**: Folding streams (fold, sum)
- **stream-transform**: Map and filter operations

These benchmarks represent the theoretical maximum performance - the floor that shibuya should approach.

### Framework Overhead

Measures the overhead of running messages through shibuya:
- **adapter-creation**: Cost of creating mock adapters and ingested messages
- **processing**: Running messages through `runWithMetrics` (full pipeline)
- **comparison**: Direct side-by-side comparison with streamly baseline

The comparison benchmarks use `bcompare` to show relative performance (e.g., "2.5x" means shibuya takes 2.5x as long).

### Handler Overhead

Measures the overhead of different handler patterns:
- **noop-handler**: Minimal handler returning `AckOk` (pure framework overhead)
- **compute-handler**: Handlers with light/medium CPU computation
- **io-handler**: Handlers performing IO operations (IORef updates)

### Dead-Letter Reason Operations

Measures application-code validation, built-in reason rendering, and
application reason rendering. The rendering fixture reuses an already validated
`DeadLetterCode`, matching the intended startup-validation pattern. These are
focused current-tree measurements; only pre-existing benchmark names participate
in a 0.8.0.1 baseline comparison.

## Memory Usage

Memory statistics are automatically collected and reported when running with RTS `-T` flag (enabled by default in the cabal file).

### Reported Metrics

| Metric | Description |
|--------|-------------|
| allocated | Total bytes allocated during benchmark iteration |
| copied | Bytes copied by GC (indicates live data pressure) |
| peak memory | Maximum heap size since process start |

### Example Output

```
All
  baseline-streamly
    stream-creation
      100-msgs:     OK
         1.54 μs ± 932 ns, 5.5 KB allocated, 0 B copied, 337 MB peak memory
      1000-msgs:    OK
         14.2 μs ± 13 μs, 55 KB allocated, 1 B copied, 337 MB peak memory
```

## Interpreting Results

### Framework Overhead Comparison

The comparison benchmarks show shibuya overhead relative to pure streamly:

```
comparison
  100-msgs
    streamly-baseline:  OK
      10.3 μs ± 6.9 μs, 96 KB allocated
    shibuya-framework:  OK
      47.3 μs ± 27 μs, 238 KB allocated, 4.19x
```

The `4.19x` suffix indicates shibuya takes 4.19 times as long as pure streamly.

### Understanding the Overhead

The shibuya overhead includes:
- NQE supervisor infrastructure setup
- Bounded inbox creation and message passing
- Metrics tracking (TVar updates)
- AckHandle creation and finalization
- Ingested message envelope wrapping

For small message counts, this fixed overhead dominates. For larger batches or when handler work is significant, the overhead becomes proportionally smaller.

### Acceptable Overhead Guidelines

| Ratio | Assessment | Notes |
|-------|------------|-------|
| < 2x | Excellent | Minimal framework overhead |
| 2x - 5x | Good | Acceptable for most use cases |
| 5x - 10x | Fair | Consider for I/O-bound workloads |
| > 10x | Investigate | May indicate performance issues |

Note: Real-world applications typically have handler work that dominates, making framework overhead negligible.

### Memory Guidelines

- **allocated** should grow linearly with message count
- **copied** should be minimal (0 for short benchmarks without GC)
- Per-message allocation should be consistent (e.g., ~55 bytes/msg for baseline)

## Benchmark Results

Results from Apple M4 Max (run with `--stdev 20 --timeout 120`):

### Baseline Streamly (Performance Floor)

| Benchmark | 100 msgs | 1000 msgs | 10000 msgs |
|-----------|----------|-----------|------------|
| stream-creation | 1.43 μs | 14.1 μs | 140 μs |
| stream-consumption | 1.47 μs | 14.4 μs | 145 μs |
| map transform | 1.48 μs | 14.6 μs | 146 μs |
| filter-map | 10.3 μs | 109 μs | 1.14 ms |

### Framework Processing

| Benchmark | 100 msgs | 1000 msgs | 10000 msgs |
|-----------|----------|-----------|------------|
| adapter-creation | 1.60 μs | 15.7 μs | 154 μs |
| runWithMetrics | 39.2 μs | 401 μs | 4.27 ms |

### Shibuya vs Streamly Comparison

| Messages | Streamly | Shibuya | Overhead Ratio |
|----------|----------|---------|----------------|
| 100 | 12.3 μs | 51.7 μs | **4.21x** |
| 1000 | 132 μs | 531 μs | **4.01x** |
| 10000 | 1.40 ms | 5.60 ms | **4.01x** |

### Handler Overhead

| Handler Type | 100 msgs | 1000 msgs | 10000 msgs |
|--------------|----------|-----------|------------|
| noop | 48.6 μs | 503 μs | 5.45 ms |
| light-compute | 50.2 μs | 507 μs | - |
| medium-compute | 50.5 μs | 526 μs | - |
| io-counter | 53.6 μs | 557 μs | 5.58 ms |

### Key Findings

1. **Consistent ~4x overhead**: Shibuya adds approximately 4x overhead compared to pure streamly, consistent across all message counts
2. **Linear scaling**: Both streamly and shibuya scale linearly with message count
3. **Handler type negligible**: Different handler types (noop, compute, IO) have minimal performance impact (~10% variance)
4. **Per-message cost**: ~0.4 μs per message through shibuya vs ~0.13 μs for pure streamly

### Memory Usage

| Benchmark | 100 msgs | 1000 msgs | 10000 msgs |
|-----------|----------|-----------|------------|
| streamly-baseline | 96 KB | 1.0 MB | 10 MB |
| shibuya-framework | 248 KB | 2.5 MB | 26 MB |

Shibuya allocates approximately 2.5x more memory than pure streamly due to:
- Ingested message envelope wrapping
- AckHandle closures
- Metrics TVar updates
- Bounded inbox overhead

## Tracing benchmarks

Every other group runs under `runTracingNoop`. The `tracing` group (`bench/Bench/Tracing.hs`)
measures the per-message tracing path. It was added as the baseline for
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`. Each cell runs
10,000 messages with a no-op handler through `runApp` and fails unless all 10,000 are
processed. The cells are:

```text
tracing/<shape>/<mode>
  shape: single-serial | single-async8 | batch100
  mode:  disabled-noheaders | disabled-headers | enabled-noheaders | enabled-headers
```

- `disabled` runs `runTracingNoop`. `enabled` runs `runTracing` with a tracer whose provider
  has one span processor that discards every span. hs-opentelemetry creates non-recording
  spans when a provider has no processors, so a processor is required for the SDK to do its
  full span construction. `newBenchTracer` aborts the run if its spans are not recording.
- `headers` gives every message the same valid `traceparent`. `noheaders` sets
  `traceContext = Nothing`.
- `batch100` is a batching processor with `batchSize = 100`.

Later plans may add cells but must not rename or remove these, because comparisons match
cells by name.

### Baseline (2026-11-12)

The run used commit `35e0e79` on an Apple M5 Ultra (36 cores, 256 GiB) with GHC 9.12.4 and
`--stdev 5 --timeout 120`. Allocation is bytes per cell, that is, per 10,000 messages.

| Cell | Time | Allocated |
|---|---:|---:|
| single-serial/disabled-noheaders | 8.56 ms | 19,890,400 |
| single-serial/disabled-headers | 9.76 ms | 23,347,428 |
| single-serial/enabled-noheaders | 28.8 ms | 86,450,191 |
| single-serial/enabled-headers | 34.4 ms | 100,058,185 |
| single-async8/disabled-noheaders | 46.2 ms | 37,953,439 |
| single-async8/disabled-headers | 58.8 ms | 41,551,267 |
| single-async8/enabled-noheaders | 226 ms | 186,560,682 |
| single-async8/enabled-headers | 255 ms | 212,232,901 |
| batch100/disabled-noheaders | 17.1 ms | 23,615,871 |
| batch100/disabled-headers | 16.2 ms | 23,668,159 |
| batch100/enabled-noheaders | 16.1 ms | 24,297,411 |
| batch100/enabled-headers | 16.0 ms | 24,426,154 |

Even with tracing disabled, `disabled-headers` allocates more than `disabled-noheaders`:
about 346 bytes per message for `single-serial` (3,457,028 bytes over 10,000 messages) and
360 bytes per message for `single-async8`. `withExtractedContext` matches on the decoded
`Maybe SpanContext` before it checks whether tracing is enabled, so the W3C header is decoded
even under `runTracingNoop`. The batch difference is small (52,288 bytes per run, about 520
bytes per batch) because only the first member of each batch is decoded.

Absolute numbers depend on the machine. Compare runs only when both sides were measured on the
same machine in the same session.

### Comparing a change against the baseline

Build the baseline from a git worktree of the baseline commit, then compare the working tree
against its CSV:

```bash
git worktree add /tmp/shibuya-tracing-baseline <baseline-commit>
( cd /tmp/shibuya-tracing-baseline && \
  cabal bench shibuya-core-bench \
    --benchmark-options="-p tracing --stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv" )
cabal bench shibuya-core-bench \
  --benchmark-options="-p tracing --stdev 5 --timeout 120 --baseline /tmp/shibuya-tracing-baseline.csv --fail-if-slower 10 --csv /tmp/shibuya-tracing-after.csv"
git worktree remove /tmp/shibuya-tracing-baseline
```

Remove `-p tracing` to compare every group. Cells that have no baseline row are reported
without a comparison.

Reading rule ([ADR 0006](../docs/adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md)):
`--fail-if-slower 10` covers time only. Compare the `Allocated` column of the two CSVs cell by
cell, and explain any increase, even when time is within noise. An unexplained allocation
increase is a regression.

The retention side of the same contract is the process-isolated test suite
`shibuya-core-trace-retention-test`:

```bash
cabal test shibuya-core:test:shibuya-core-trace-retention-test --enable-tests --test-show-details=direct
```

## Configuration

The benchmarks use these default RTS settings (configured in cabal file):

| Flag | Value | Purpose |
|------|-------|---------|
| `-N` | all cores | Parallel execution |
| `-T` | enabled | GC statistics for memory reporting |
| `-A32m` | 32MB | Large allocation area (reduces GC noise) |
| `-O2` | enabled | Full optimizations |

## Architecture

```
shibuya-core-bench/
├── shibuya-core-bench.cabal   # Package configuration
├── README.md                  # This file
└── bench/
    ├── Main.hs               # Entry point, combines all benchmarks
    ├── Test/LifecycleLoad.hs # One-scenario JSON production load executable
    └── Bench/
        ├── Baseline.hs       # Pure streamly benchmarks
        ├── Framework.hs      # Shibuya overhead comparison
        ├── Handler.hs        # Handler pattern benchmarks
        └── Lifecycle.hs      # Shared lifecycle scenario catalog and measurements
```

### Benchmark Design

- **Baseline.hs**: Uses pure streamly with simple `BenchMessage` records
- **Framework.hs**: Uses `listAdapter` with mock `Ingested` messages, runs through `runWithMetrics`
- **Handler.hs**: Various handler implementations testing different workload patterns

All benchmarks use the same message type for fair comparison:

```haskell
data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text
  }
```

## Tips for Accurate Benchmarks

1. **Close other applications** - Reduces noise from competing processes
2. **Disable CPU throttling** - Consistent clock speeds improve reproducibility
3. **Run multiple times** - Use `--stdev 5` for high precision
4. **Use adequate timeout** - Framework benchmarks may need `--timeout 120` or more
5. **Check for GC** - Non-zero `copied` bytes indicate GC occurred during measurement

## Troubleshooting

### Benchmarks timeout

The `io-bound` and `concurrency-levels` groups deliberately sleep in their
handlers and use wall-clock time. Other groups retain the default CPU timing.
[tasty-bench](mori://Bodigrim/tasty-bench/packages/tasty-bench) excludes sleeping
time from its default CPU clock and also uses that clock to estimate sampling
time remaining. Delay-heavy workloads can therefore hit the wall-clock timeout
while the sampler keeps increasing repetitions. Increasing the timeout alone
does not correct the clock mismatch.

When comparing against a release predating this timing fix, apply the same
benchmark-only patch to the detached baseline worktree before building either
benchmark. Both sides must use the same clock for each benchmark; discard CSVs
captured with the previous clock. Keep the workload, precision target, timeout,
RTS settings, and regression threshold unchanged.

Use matching lifecycle fixtures as well. In particular, the full-inbox capture
fix advanced the lifecycle workload version from 3 to 4 and changed its shared
driver. When the baseline API is compatible, overlay the current
`bench/Bench/Lifecycle.hs` in the baseline worktree while retaining the old
Shibuya runtime source. A fixture-version difference must not be attributed to
the runtime's allocation cost.

The framework benchmarks include full supervisor setup which takes longer. Increase timeout:

```bash
cabal bench shibuya-core-bench --benchmark-options="--timeout 120"
```

### High variance in results

Reduce standard deviation target (takes longer but more accurate):

```bash
cabal bench shibuya-core-bench --benchmark-options="--stdev 5"
```

### Memory not reported

Ensure the `-T` RTS flag is enabled (it's in the cabal file by default). If running directly:

```bash
./shibuya-core-bench +RTS -T
```

## Implementation Notes

### runWithMetrics vs runSupervised

The standalone `runWithMetrics` and `runWithMetricsBatch` helpers block until the
source ends and processing drains. Both run the ingester and consumer concurrently,
so any positive inbox capacity can provide backpressure; capacity does not have to
match the message count. The existing benchmark inbox sizes remain unchanged.

These blocking helpers return their processor handle only after completion and
expose no live pause capability. Their ingesters retain metrics and tracing while
omitting unreachable pause checks. Supervised processors return a live handle and
retain pause/resume admission checks before each source step.
