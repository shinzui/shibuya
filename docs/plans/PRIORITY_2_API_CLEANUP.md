# Priority 2: API Cleanup

These issues affect API usability, module organization, and coupling to external libraries. Fixing them improves the developer experience and future maintainability.

---

## 2.1 Hide Internal Modules

### Problem
Implementation detail modules are exposed in the public API via `exposed-modules` in cabal:

```cabal
exposed-modules:
  Shibuya.Runner.Ingester    -- Internal: stream-to-inbox bridge
  Shibuya.Runner.Processor   -- Internal: inbox-to-handler loop
  Shibuya.Runner.Serial      -- Internal: alternative runner
```

Users may depend on these, making refactoring difficult.

### Files to Modify
- `shibuya-core.cabal`
- Possibly rename modules to `Shibuya.Internal.*`

### Implementation Plan

#### Option A: Move to other-modules (Simple)

##### Step 1: Update cabal file
```cabal
library
  exposed-modules:
    Shibuya.Adapter
    Shibuya.Adapter.Mock
    Shibuya.App
    Shibuya.Core
    Shibuya.Core.Ack
    Shibuya.Core.AckHandle
    Shibuya.Core.Ingested
    Shibuya.Core.Lease
    Shibuya.Core.Types
    Shibuya.Handler
    Shibuya.Policy
    Shibuya.Prelude
    Shibuya.Runner
    Shibuya.Runner.Master
    Shibuya.Runner.Metrics
    Shibuya.Runner.Supervised
    Shibuya.Stream

  other-modules:
    Shibuya.Runner.Ingester   -- Hidden
    Shibuya.Runner.Processor  -- Hidden
    Shibuya.Runner.Serial     -- Hidden
```

##### Step 2: Verify builds
Ensure the library still builds and tests pass.

#### Option B: Create Internal namespace (More Explicit)

##### Step 1: Create internal module hierarchy
```
src/Shibuya/Internal/
  Ingester.hs
  Processor.hs
  Serial.hs
```

##### Step 2: Update imports in Supervised.hs, etc.
```haskell
-- Old
import Shibuya.Runner.Ingester (runIngester)

-- New
import Shibuya.Internal.Ingester (runIngester)
```

##### Step 3: Update cabal
```cabal
other-modules:
  Shibuya.Internal.Ingester
  Shibuya.Internal.Processor
  Shibuya.Internal.Serial
```

### Recommendation
**Option A** is simpler and sufficient. Option B is better if you want to clearly signal "internal" in import statements.

### Breaking Changes
- Users importing hidden modules will get compilation errors
- This is intentional - they shouldn't depend on internals

### Migration Guide
```markdown
## Migrating from 0.1.x to 0.2.x

### Removed Exports
The following modules are no longer publicly exported:
- `Shibuya.Runner.Ingester` - Use `Shibuya.App.runApp` instead
- `Shibuya.Runner.Processor` - Use `Shibuya.App.runApp` instead
- `Shibuya.Runner.Serial` - Use `Shibuya.App.runApp` instead

If you have a use case requiring direct access to these modules,
please open an issue.
```

---

## 2.2 Complete Core.hs Exports

### Problem
`Shibuya.Core` exports `runApp` but not the types needed to use it effectively:

```haskell
-- Current: Users must do
import Shibuya.Core (runApp, ...)
import Shibuya.App (QueueProcessor(..), AppHandle, waitApp, stopApp, getAppMetrics)

-- Expected: Single import should suffice
import Shibuya.Core
```

### Files to Modify
- `src/Shibuya/Core.hs`

### Implementation Plan

#### Step 1: Audit what's needed to use runApp
```haskell
-- To call runApp, users need:
runApp :: Strategy -> Int -> [(ProcessorId, QueueProcessor es)] -> ...

-- Therefore they need:
-- - Strategy (already exported)
-- - ProcessorId (already exported)
-- - QueueProcessor (MISSING)

-- To use the result, they need:
-- - AppHandle (MISSING)
-- - AppError (MISSING - wait, this IS exported)
-- - waitApp (MISSING)
-- - stopApp (MISSING)
-- - getAppMetrics (MISSING)
```

#### Step 2: Add missing exports to Core.hs
```haskell
module Shibuya.Core
  ( -- ... existing exports ...

    -- * App Types (NEW)
    QueueProcessor (..),
    AppHandle (..),

    -- * App Operations (NEW)
    waitApp,
    stopApp,
    getAppMetrics,
  )
where

import Shibuya.App
  ( AppError (..),
    QueueProcessor (..),  -- NEW
    AppHandle (..),       -- NEW
    runApp,
    waitApp,              -- NEW
    stopApp,              -- NEW
    getAppMetrics,        -- NEW
  )
```

#### Step 3: Update documentation
Add example in module haddock:
```haskell
-- | Shibuya Core - Public API
--
-- Import this module for application development:
--
-- @
-- import Shibuya.Core
--
-- main = runEff $ do
--   let processor = QueueProcessor myAdapter myHandler
--   result <- runApp IgnoreAll 100 [(ProcessorId "main", processor)]
--   case result of
--     Right handle -> waitApp handle
--     Left err -> print err
-- @
```

#### Step 4: Verify example compiles with single import
Create a test file that only imports `Shibuya.Core` and uses all common operations.

### Breaking Changes
None - only additions.

### Consideration: Re-export Everything?
Should `Core.hs` also re-export:
- `listAdapter` from `Adapter.Mock`?
- Stream utilities from `Shibuya.Stream`?

Recommendation: Keep `Core.hs` focused on the main API. Users needing mock adapters or stream utilities can import those modules directly.

---

## 2.3 Remove Unused Parameters

### Problem
Several functions have parameters documented as "unused" or that have no effect:

```haskell
-- Supervised.hs:141
runWithMetrics ::
  Natural ->  -- "Inbox size (unused, for API compatibility)"
  ProcessorId ->
  ...

-- Serial.hs:29
runSerial ::
  Natural ->  -- "Inbox size (unused in serial mode, for API compatibility)"
  ...
```

### Files to Modify
- `src/Shibuya/Runner/Supervised.hs`
- `src/Shibuya/Runner/Serial.hs`
- `src/Shibuya/Core.hs` (if these are exported)

### Implementation Plan

#### Decision Point: Remove or Implement?

**If backpressure will be implemented (Priority 1.1):**
- Keep the parameter, it will be used soon
- Update comment to say "Reserved for backpressure implementation"

**If backpressure is deferred:**
- Remove unused parameters to avoid confusion

#### Path A: Keep and Document (If implementing backpressure soon)

##### Step 1: Update comments
```haskell
runWithMetrics ::
  -- | Inbox size for backpressure.
  -- Currently unused; will be implemented in a future version.
  -- See: https://github.com/xxx/shibuya/issues/NN
  Natural ->
  ...
```

#### Path B: Remove (If backpressure is deferred)

##### Step 1: Remove from runWithMetrics
```haskell
-- Old
runWithMetrics :: Natural -> ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor

-- New
runWithMetrics :: ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor
```

##### Step 2: Update callers
Search for all uses of `runWithMetrics` and remove the first argument.

##### Step 3: Remove from runSerial (if keeping Serial.hs)
```haskell
-- Old
runSerial :: Natural -> Adapter es msg -> Handler es msg -> Eff es ()

-- New
runSerial :: Adapter es msg -> Handler es msg -> Eff es ()
```

##### Step 4: Update Core.hs exports if affected

### Recommendation
Given that Priority 1.1 is to implement backpressure, **Path A (keep and document)** is better. Once backpressure is implemented, the parameter becomes meaningful.

### Breaking Changes
- Path B removes a parameter (breaking for callers)
- Path A is non-breaking

---

## 2.4 Define Own Strategy Type

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
-- New file: src/Shibuya/Supervision.hs
-- Or add to App.hs

module Shibuya.Supervision
  ( SupervisionStrategy (..)
  ) where

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

#### Step 2: Create conversion function
```haskell
-- Internal, not exported
toNQEStrategy :: SupervisionStrategy -> NQE.Strategy
toNQEStrategy = \case
  IgnoreFailures -> NQE.IgnoreAll
  StopAllOnFailure -> NQE.KillAll
  RestartOnFailure -> NQE.OneForOne
```

#### Step 3: Update runApp signature
```haskell
-- Old
runApp :: Strategy -> Int -> [(ProcessorId, QueueProcessor es)] -> ...

-- New
runApp :: SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor es)] -> ...
```

#### Step 4: Update startMaster
```haskell
-- Old
startMaster :: Strategy -> Eff es Master

-- New (internal, takes NQE.Strategy)
startMaster :: NQE.Strategy -> Eff es Master

-- Or update to take SupervisionStrategy and convert internally
```

#### Step 5: Update Core.hs exports
```haskell
-- Old
import Control.Concurrent.NQE.Supervisor (Strategy (..))

-- New
import Shibuya.Supervision (SupervisionStrategy (..))
-- Don't export NQE.Strategy
```

#### Step 6: Update documentation
```haskell
-- | Supervision strategy for handling processor failures.
--
-- @
-- -- Keep running even if processors fail
-- runApp IgnoreFailures 100 processors
--
-- -- Stop everything if any processor fails
-- runApp StopAllOnFailure 100 processors
--
-- -- Restart individual failed processors
-- runApp RestartOnFailure 100 processors
-- @
data SupervisionStrategy = ...
```

### Breaking Changes
- Type name changes from `Strategy` to `SupervisionStrategy`
- Constructor names change (e.g., `IgnoreAll` → `IgnoreFailures`)

### Migration Guide
```markdown
## Strategy Type Renamed

The supervision strategy type has been renamed for clarity:

| Old (NQE) | New (Shibuya) |
|-----------|---------------|
| `Strategy` | `SupervisionStrategy` |
| `IgnoreAll` | `IgnoreFailures` |
| `IgnoreGraceful` | (removed - use IgnoreFailures) |
| `KillAll` | `StopAllOnFailure` |
| `OneForOne` | `RestartOnFailure` |

Update your code:
```haskell
-- Old
import Control.Concurrent.NQE.Supervisor (Strategy(..))
runApp IgnoreAll 100 processors

-- New
import Shibuya.Core (SupervisionStrategy(..))
runApp IgnoreFailures 100 processors
```
```

### Consideration: Which NQE strategies to expose?
NQE has: `IgnoreAll`, `IgnoreGraceful`, `KillAll`, `OneForOne`, `OneForAll`

Recommendation: Start with the three most common:
- `IgnoreFailures` (IgnoreAll)
- `StopAllOnFailure` (KillAll)
- `RestartOnFailure` (OneForOne)

Add others if users request them.

---

## Implementation Order

Recommended order:

1. **2.2 Complete Core.hs Exports** - Quick win, improves ergonomics
2. **2.1 Hide Internal Modules** - Simple cabal change
3. **2.3 Remove Unused Parameters** - Depends on Priority 1.1 decision
4. **2.4 Define Own Strategy Type** - Larger change, can be deferred

## Estimated Scope

| Item | Complexity | Files Changed | Breaking |
|------|------------|---------------|----------|
| 2.1 Hide Internals | Low | 1 (cabal) | Minor |
| 2.2 Core.hs Exports | Low | 1 | No |
| 2.3 Unused Params | Low | 2-3 | Maybe |
| 2.4 Own Strategy | Medium | 3-4 | Yes |

## Version Strategy

Consider bundling breaking changes:

**v0.1.1** (non-breaking):
- 2.2 Complete Core.hs exports

**v0.2.0** (breaking):
- 2.1 Hide internal modules
- 2.3 Remove unused parameters (if removing)
- 2.4 Define own Strategy type
