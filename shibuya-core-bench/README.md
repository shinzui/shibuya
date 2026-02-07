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
    └── Bench/
        ├── Baseline.hs       # Pure streamly benchmarks
        ├── Framework.hs      # Shibuya overhead comparison
        └── Handler.hs        # Handler pattern benchmarks
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

The benchmarks use `runWithMetrics` which is a **test helper** designed for simple, finite streams. It has an important constraint:

**⚠️ Inbox size must be >= message count when using `runWithMetrics`**

This is because `runWithMetrics` runs the ingester and processor **sequentially**:

```haskell
-- Sequential execution in runWithMetrics:
runIngesterWithMetrics metricsVar adapter.source inbox  -- pushes ALL messages
drainInboxWithMetrics metricsVar handler inbox          -- then drains
```

If the inbox capacity is smaller than the message count, the ingester blocks waiting for space that will never be freed (since draining hasn't started yet), causing a **deadlock**.

**Production code uses `runSupervised`** which runs ingester and processor **concurrently**, so backpressure works correctly with any inbox size:

```haskell
-- Concurrent execution in runSupervised:
UIO.withAsync ingesterWithSignal $ \_ ->
  processUntilDrained metricsVar handler inbox  -- drains while ingester pushes
```

This is not a bug in shibuya-core - it's a design constraint of the test helper. The benchmarks account for this by setting inbox size equal to message count.
