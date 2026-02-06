# Failing Benchmarks

This document tracks benchmarks that fail due to incompatibilities between the `pgmq-hasql` library and the installed pgmq schema version.

## Summary

21 out of 67 benchmarks fail due to function signature mismatches between what `pgmq-hasql` expects and what the pgmq schema provides.

## Root Cause

The `pgmq-hasql` library was written against a different version of the pgmq PostgreSQL schema. Several functions either:
- Don't exist in the current schema
- Have different argument signatures
- Have different argument ordering

## Failing Functions

### 1. `pgmq.pop(queue, qty)` - Batch Pop

**Expected by pgmq-hasql:**
```sql
pgmq.pop(queue_name text, qty integer)
```

**Actual in schema:**
```sql
pgmq.pop(queue_name text)  -- Returns single message only
```

**Affected benchmarks:**
- `ack/pop/single`
- `ack/pop/batch-10`
- `throughput/read-only/pop-100`
- `throughput/read-only/pop-1000`
- `throughput/burst/burst-100`
- `throughput/burst/burst-1000`
- `concurrent/scaling/1-worker`
- `concurrent/scaling/2-workers`
- `concurrent/scaling/4-workers`

**Error:**
```
function pgmq.pop(text, integer) does not exist
```

---

### 2. `pgmq.set_vt(queue, bigint[], vt)` - Batch Set Visibility Timeout

**Expected by pgmq-hasql:**
```sql
pgmq.set_vt(queue_name text, msg_ids bigint[], vt_offset integer)
```

**Actual in schema:**
```sql
pgmq.set_vt(queue_name text, msg_id bigint, vt_offset integer)  -- Single message only
```

**Affected benchmarks:**
- `ack/set-vt/batch-10`

**Error:**
```
function pgmq.set_vt(text, bigint[], integer) does not exist
```

---

### 3. `pgmq.read_with_poll` - Argument Order Mismatch

**Expected by pgmq-hasql:**
```sql
pgmq.read_with_poll(queue_name, vt, qty, max_poll_seconds, poll_interval_ms, conditional)
```

**Actual in schema:**
```sql
pgmq.read_with_poll(queue_name, vt, qty, conditional, max_poll_seconds, poll_interval_ms)
-- Note: conditional is 4th argument, not 6th
```

**Affected benchmarks:**
- `read/poll/poll-immediate`
- `read/poll/poll-batch-10`

**Error:**
```
function pgmq.read_with_poll(text, integer, integer, integer, integer, jsonb) does not exist
```

---

### 4. `pgmq.create_fifo_index` - Function Does Not Exist

**Expected by pgmq-hasql:**
```sql
pgmq.create_fifo_index(queue_name text)
```

**Actual in schema:**
Function does not exist. FIFO functionality may require manual index creation or a different approach.

**Affected benchmarks:**
- `fifo/grouped/read-10`
- `fifo/grouped/read-50`
- `fifo/round-robin/read-10`
- `fifo/round-robin/read-50`
- `fifo/group-count/single-group`
- `fifo/group-count/10-groups`
- `fifo/group-count/100-groups`

**Error:**
```
function pgmq.create_fifo_index(text) does not exist
```

---

### 5. `pgmq.metrics_all()` - Ambiguous Column Reference

**Expected behavior:**
```sql
SELECT * FROM pgmq.metrics_all()
```

**Actual behavior:**
Query fails due to ambiguous `queue_name` column reference in the function implementation.

**Affected benchmarks:**
- `multi/metrics/all-queues`

**Error:**
```
column reference "queue_name" is ambiguous
```

---

## Recommendations

### Option 1: Update pgmq-hasql Library

Modify `pgmq-hasql` to match the current pgmq schema function signatures:
- Remove batch `pop` support or implement client-side batching
- Remove batch `set_vt` support or implement client-side batching
- Fix `read_with_poll` argument ordering
- Remove or replace `create_fifo_index` calls
- Investigate `metrics_all` query

### Option 2: Update pgmq Schema

Install a version of pgmq that matches `pgmq-hasql` expectations:
- Add `pop(queue, qty)` overload
- Add `set_vt(queue, bigint[], vt)` overload
- Add `create_fifo_index` function
- Fix `metrics_all` ambiguous column

### Option 3: Skip Incompatible Benchmarks

Run benchmarks with a filter to skip failing tests:
```bash
cabal bench shibuya-pgmq-adapter-bench --enable-benchmarks \
  --benchmark-options="--time-mode wall -p '!/pop|set-vt.batch|poll|fifo|metrics.all/'"
```

## Working Benchmarks

The following benchmark categories work correctly:
- `send/*` - All send operations
- `read/single`, `read/batch/*` - Non-polling reads
- `ack/delete/*` - Delete operations
- `ack/archive/*` - Archive operations
- `ack/set-vt/single` - Single message visibility timeout
- `multi/send-round-robin/*` - Multi-queue sends
- `multi/read-all/*` - Multi-queue reads
- `multi/lifecycle/*` - Queue create/drop
- `multi/metrics/single-queue` - Single queue metrics
- `throughput/send-only/*` - Send throughput
- `throughput/full-cycle/*` - Full message lifecycle
- `concurrent/readers/*` - Concurrent readers
- `concurrent/writers/*` - Concurrent writers
- `concurrent/mixed/*` - Mixed read/write
- `raw-vs-effectful/*` - All raw vs effectful comparisons
