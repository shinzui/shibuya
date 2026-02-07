# shibuya-pgmq-adapter-bench

Comprehensive benchmarks for `shibuya-pgmq-adapter` using [tasty-bench](https://hackage.haskell.org/package/tasty-bench).

## Prerequisites

- PostgreSQL running with pgmq schema installed
- `PG_CONNECTION_STRING` environment variable set

## Running Benchmarks

### 1. Start PostgreSQL

If using the project's process-compose:

```bash
just process-up
```

Or start PostgreSQL manually and ensure the database exists.

### 2. Set Connection String

The benchmarks require a PostgreSQL connection string:

```bash
# For unix socket (typical local development)
export PGHOST="$PWD/db"
export PGDATABASE=shibuya
export PG_CONNECTION_STRING="postgresql:///shibuya?host=$(jq -rn --arg x "$PGHOST" '$x|@uri')"

# Or for TCP connection
export PG_CONNECTION_STRING="postgresql://localhost:5432/shibuya"
```

### 3. Run Benchmarks

```bash
# Run all benchmarks
cabal bench shibuya-pgmq-adapter-bench

# Run with custom settings
cabal bench shibuya-pgmq-adapter-bench --benchmark-options="--stdev 10"

# Run specific benchmark patterns (uses tasty pattern matching)
cabal bench shibuya-pgmq-adapter-bench --benchmark-options="-p send"
```

## Configuration

Environment variables for customizing benchmark behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_CONNECTION_STRING` | (required) | PostgreSQL connection string |
| `BENCH_MESSAGE_COUNT` | 1000 | Number of messages for throughput tests |
| `BENCH_BATCH_SIZES` | 1,10,50,100 | Batch sizes to benchmark |
| `BENCH_QUEUE_COUNT` | 4 | Number of queues for multi-queue tests |
| `BENCH_CONCURRENCY` | 4 | Concurrent workers for concurrency tests |
| `BENCH_PAYLOAD_SIZES` | small,medium,large | Payload size variants |
| `BENCH_SKIP_CLEANUP` | false | Skip queue cleanup after benchmarks |

## Benchmark Categories

### Send Benchmarks
- Single message send
- Batch sends (10, 100, 1000 messages)
- Send with headers / FIFO group headers
- Delayed sends (5s, 30s delay)
- Payload sizes (100B, 10KB, 100KB)

### Read Benchmarks
- Single message read
- Batch reads (10, 50, 100 messages)
- Polling operations

### Ack Benchmarks
- Delete (single and batch)
- Archive (single and batch)
- Visibility timeout updates
- Pop operations

### FIFO Benchmarks
- Grouped reads
- Round-robin reads
- Group count variations (1, 10, 100 groups)

### Multi-Queue Benchmarks
- Round-robin send across queues
- Read from all queues
- Queue lifecycle (create/drop)
- Metrics collection

### Throughput Benchmarks
- Send-only (100, 1000 messages)
- Read-only (pop 100, 1000 messages)
- Full cycle (send-read-delete)
- Burst operations

### Concurrent Benchmarks
- Multiple readers (2, 4, 8)
- Multiple writers (2, 4, 8)
- Mixed read/write workloads
- Scaling tests

### Raw vs Effectful Comparison
- Direct pgmq-hasql vs effectful layer overhead
- Send, read, and ack operations compared

## Benchmark Results

Results from Apple M4 Max with PostgreSQL 17:

### Send Operations

| Benchmark | Time |
|-----------|------|
| Single send | 177 μs |
| Batch 10 | 203 μs |
| Batch 100 | 374 μs |
| Batch 1000 | 2.02 ms |
| With headers | ~200 μs |
| Small payload (100B) | ~180 μs |
| Medium payload (10KB) | ~190 μs |
| Large payload (100KB) | ~200 μs |

### Read Operations

| Benchmark | Time |
|-----------|------|
| Read single | ~30 ms |
| Read batch 10 | ~95 ms |
| Read batch 50 | ~100 ms |
| Read batch 100 | ~98 ms |
| Poll immediate | ~30 ms |

### Ack Operations

| Benchmark | Time |
|-----------|------|
| Delete single | ~102 ms |
| Delete batch 10 | ~88 ms |
| Delete batch 100 | ~95 ms |
| Archive single | ~110 ms |
| Archive batch 10 | ~90 ms |
| Pop single | ~114 ms |
| Pop batch 10 | ~105 ms |

### FIFO Operations

| Benchmark | Time |
|-----------|------|
| Read grouped 10 | ~1.37 s |
| Read grouped 50 | ~1.39 s |
| Round-robin 10 | ~84 ms |
| Round-robin 50 | ~98 ms |

### Throughput

| Benchmark | Time |
|-----------|------|
| Send 100 msgs | ~34 ms |
| Send 1000 msgs | ~97 ms |
| Batch send 1000 | ~27 ms |
| Pop 100 msgs | ~29 ms |
| Pop 1000 msgs | ~41 ms |
| Full cycle 100 | ~23 ms |
| Full cycle 1000 | ~54 ms |

### Concurrent Operations

| Benchmark | Time |
|-----------|------|
| 2 readers | ~110 ms |
| 4 readers | ~120 ms |
| 8 readers | ~172 ms |
| 2 writers | ~34 ms |
| 4 writers | ~34 ms |
| 8 writers | ~41 ms |
| 2r-2w mixed | ~122 ms |
| 4r-4w mixed | ~123 ms |

### Raw hasql vs Effectful Layer

| Operation | Raw hasql | Effectful |
|-----------|-----------|-----------|
| Send single | ~19 ms | ~20 ms |
| Batch send 100 | ~21 ms | ~22 ms |
| Read batch 10 | ~102 ms | ~123 ms |
| Delete | ~137 ms | ~105 ms |

The effectful layer adds minimal overhead (~5-20%) for most operations.

## Notes

- Read benchmarks include seeding the queue with messages before running
- Times include queue setup/teardown overhead for some benchmarks
- Results may vary based on PostgreSQL configuration and hardware
- FIFO grouped reads are significantly slower due to the additional ordering constraints
