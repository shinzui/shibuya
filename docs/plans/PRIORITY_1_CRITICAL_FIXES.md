# Priority 1: Critical Fixes (API/Behavior Mismatch)

> **Note:** This is pre-release development (v0.1.0.0). Breaking changes are expected and not a concern until the first stable release.

These issues represent gaps between documented/expected behavior and actual implementation.

---

## 1.1 Implement Backpressure ✅ COMPLETED

**Status:** Implemented in commit `31427e2`

### Summary
Backpressure is now implemented via NQE's bounded inbox. The `inboxSize` parameter in `runSupervised` and `runWithMetrics` controls the inbox capacity.

### Architecture
```
Adapter.source → Ingester (async) → Bounded Inbox → Processor → Handler
```

### Key Changes
- `Supervised.hs`: Uses `newBoundedInbox inboxSize` to create bounded channel
- `Ingester.hs`: Added `runIngesterWithMetrics` to track received count
- `Processor.hs`: Added `drainInbox` for processing remaining messages after stream exhausts

### Behavior
- **Blocking backpressure**: When inbox is full, ingester blocks until space is available
- **Graceful shutdown**: Processor drains remaining messages when stream completes
- **Metrics tracking**: `received` incremented by ingester, `processed`/`failed` by processor

---

## 1.2 Implement AckHalt ✅ COMPLETED

**Status:** Implemented using exception-based approach with halt isolation.

### Summary
`AckHalt` now properly stops processing. When a handler returns `AckHalt`, only that processor stops while other processors continue running independently.

### Architecture
- **Exception-based signaling**: `ProcessorHalt` exception thrown on `AckHalt`
- **Halt isolation**: `runSupervised` catches `ProcessorHalt` to prevent propagation via `link`
- **Metrics update**: State set to `Failed` with halt reason text before stopping

### Key Changes
- `Halt.hs` (new): Defines `ProcessorHalt` exception type
- `Supervised.hs`: Throws `ProcessorHalt` after updating metrics; catches for halt isolation
- `Processor.hs`: Removed TODO comment, cleaned up unused import

### Behavior
- **Halt stops processing**: Handler returning `AckHalt` terminates that processor
- **Halt isolation**: Other processors continue unaffected
- **Unexpected exceptions propagate**: Bugs/resource errors still propagate via `link`
- **Metrics reflect state**: Processor state shows `Failed` with halt reason

### Tests Added
- `stops processing when handler returns AckHalt`
- `updates metrics to halted state on AckHalt`
- `halt in one supervised processor doesn't affect others`

---

## 1.3 Enforce or Remove Policy Types

### Problem
`Ordering` and `Concurrency` policies are defined but never used:
- `validatePolicy` is never called
- `Async` and `Ahead` concurrency modes do nothing
- `RunnerConfig` holds these but is unused

### Files to Modify
- `src/Shibuya/App.hs` - Add validation
- `src/Shibuya/Runner/Supervised.hs` - Implement concurrency modes OR
- `src/Shibuya/Policy.hs` - Simplify if removing

### Recommendation: Remove Until Needed

Since this is pre-release, simplify by removing unused code:

1. Remove `RunnerConfig` (entirely unused)
2. Simplify `Concurrency` to just `Serial`
3. Keep `Ordering` for documentation but don't enforce
4. Remove `validatePolicy` or keep as internal

### Implementation
```haskell
-- Simplified Policy.hs
data Concurrency = Serial
  deriving stock (Eq, Show, Generic)

-- Ordering kept for future use
data Ordering = StrictInOrder | PartitionedInOrder | Unordered
  deriving stock (Eq, Show, Generic)
```

### Test Plan
1. Verify build after removing unused types
2. Update any imports that reference removed types

---

## 1.4 Document Actual Behavior

### Problem
Documentation may describe features inaccurately. Need to ensure docs match implementation.

### Files to Review
- `docs/USAGE_GUIDE.md`
- `docs/HIGH_LEVEL_ARCHITECTURE.md`
- `docs/UNIFIED_ARCHITECTURE.md`
- `README.md`

### Implementation Plan

#### Step 1: Update feature status in docs
```markdown
| Feature | Status |
|---------|--------|
| Serial Processing | ✅ Implemented |
| Metrics & Introspection | ✅ Implemented |
| NQE Supervision | ✅ Implemented |
| Backpressure | ✅ Implemented |
| Halt-on-Error (AckHalt) | ✅ Implemented |
| Async Processing | 🔲 Planned |
```

#### Step 2: Add "Current Limitations" section
```markdown
## Current Limitations

### Concurrency Modes
Currently all processing is **serial** (one message at a time per processor).
The `Ahead` and `Async` concurrency modes are planned for a future release.
```

#### Step 3: Ensure README is accurate
- Update feature list to match reality
- Remove claims about unimplemented features

---

## Implementation Order

Recommended order to implement remaining fixes:

1. **1.3 Remove Unused Policies** - Simplify codebase
2. **1.4 Document Actual Behavior** - Ensure accuracy

## Progress

| Item | Status | Complexity |
|------|--------|------------|
| 1.1 Backpressure | ✅ Done | High |
| 1.2 AckHalt | ✅ Done | Medium |
| 1.3 Policies | 🔲 Pending | Low |
| 1.4 Documentation | 🔲 Pending | Low |
