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

## 2.3 Define Own Strategy Type ✅ COMPLETED

**Status:** Implemented. Shibuya now has its own `SupervisionStrategy` type.

### Summary
Users are decoupled from NQE's internal API. The public API now uses Shibuya's own `SupervisionStrategy` type which is converted internally to NQE's `Strategy`.

### Changes Made

#### Shibuya's SupervisionStrategy type (in App.hs)
```haskell
data SupervisionStrategy
  = -- | Ignore all child exits, keep running.
    -- Failed processors are marked as Failed in metrics but don't affect others.
    IgnoreFailures
  | -- | Stop all processors if any fails.
    -- A single processor failure triggers shutdown of all processors.
    StopAllOnFailure
  deriving stock (Eq, Show, Generic)
```

#### Internal conversion (in App.hs)
```haskell
toNQEStrategy :: SupervisionStrategy -> NQE.Strategy
toNQEStrategy = \case
  IgnoreFailures -> NQE.IgnoreAll
  StopAllOnFailure -> NQE.KillAll
```

#### Core.hs exports
- Exports `SupervisionStrategy (..)` instead of NQE's `Strategy`
- Removed low-level `startMaster`/`stopMaster` exports (users should use `runApp`)
- Users who need low-level Master API can import from `Shibuya.Runner.Master` directly

### Note on NQE Strategies
NQE supports: `Notify`, `KillAll`, `IgnoreGraceful`, `IgnoreAll` (no restart semantics).
Shibuya exposes the two most common strategies. Additional strategies can be added if needed.

---

## Progress

| Item | Status | Complexity |
|------|--------|------------|
| 2.1 Hide Internals | ✅ Done | Low |
| 2.2 Core.hs Exports | ✅ Done | Low |
| 2.3 Own Strategy | ✅ Done | Medium |

All Priority 2 items have been completed.
