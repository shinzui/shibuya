# Priority 2: API Cleanup

> **Note:** This is pre-release development (v0.1.0.0). Breaking changes are expected and not a concern until the first stable release.

These issues affect API usability, module organization, and coupling to external libraries. Fixing them improves the developer experience and future maintainability.

---

## 2.1 Hide Internal Modules ✅ COMPLETED

**Status:** Implemented. Internal modules moved to `other-modules`.

### Summary
Implementation detail modules are now hidden from the public API. `ProcessorHalt` is re-exported from `Shibuya.Core` for users who need to catch halt exceptions.

### Changes Made
```cabal
exposed-modules:
  -- Public API only

other-modules:
  Shibuya.Runner.Halt       -- Hidden (ProcessorHalt re-exported via Core)
  Shibuya.Runner.Ingester   -- Hidden
  Shibuya.Runner.Processor  -- Hidden
  Shibuya.Runner.Serial     -- Hidden
```

---

## 2.2 Complete Core.hs Exports ✅ COMPLETED

**Status:** Implemented. Core.hs now exports all App types and operations.

### Summary
Users can now use a single import for the full public API:

```haskell
import Shibuya.Core
```

### Exports Added
- `QueueProcessor (..)`
- `AppHandle (..)`
- `waitApp`
- `stopApp`
- `getAppMetrics`

### Documentation
Added usage example to module haddock.

---

## 2.3 Define Own Strategy Type

### Problem
`Strategy` is re-exported directly from NQE:

```haskell
-- App.hs
import Control.Concurrent.NQE.Supervisor (Strategy (..))

-- Core.hs
import Control.Concurrent.NQE.Supervisor (Strategy (..))
```

This couples users to NQE's API. If NQE changes `Strategy`, Shibuya's API breaks.

### Files to Modify
- `src/Shibuya/App.hs` - Define and convert
- `src/Shibuya/Core.hs` - Export own type
- `src/Shibuya/Runner/Master.hs` - Use own type

### Implementation Plan

#### Step 1: Define Shibuya's own Strategy type
```haskell
-- In App.hs or new Shibuya/Supervision.hs

-- | Supervision strategy for processor failures.
data SupervisionStrategy
  = -- | Ignore all child exits, keep running
    IgnoreFailures
  | -- | Stop all processors if any fails
    StopAllOnFailure
  | -- | Restart failed processor (one-for-one)
    RestartOnFailure
  deriving stock (Eq, Show, Generic)
```

#### Step 2: Create internal conversion function
```haskell
toNQEStrategy :: SupervisionStrategy -> NQE.Strategy
toNQEStrategy = \case
  IgnoreFailures -> NQE.IgnoreAll
  StopAllOnFailure -> NQE.KillAll
  RestartOnFailure -> NQE.OneForOne
```

#### Step 3: Update runApp signature
```haskell
runApp :: SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor es)] -> ...
```

#### Step 4: Update Core.hs exports
```haskell
-- Export Shibuya's type, not NQE's
import Shibuya.App (SupervisionStrategy (..))
```

### Consideration: Which NQE strategies to expose?
NQE has: `IgnoreAll`, `IgnoreGraceful`, `KillAll`, `OneForOne`, `OneForAll`

Start with the three most common:
- `IgnoreFailures` (IgnoreAll)
- `StopAllOnFailure` (KillAll)
- `RestartOnFailure` (OneForOne)

Add others if needed.

---

## Implementation Order

1. **2.2 Complete Core.hs Exports** - Quick win, improves ergonomics
2. **2.3 Define Own Strategy Type** - Decouples from NQE

## Progress

| Item | Status | Complexity |
|------|--------|------------|
| 2.1 Hide Internals | ✅ Done | Low |
| 2.2 Core.hs Exports | ✅ Done | Low |
| 2.3 Own Strategy | 🔲 Pending | Medium |
