# Shibuya Project Context

Shibuya is a supervised queue processing framework for Haskell, inspired by Broadway (Elixir). It provides unified queue abstraction, NQE-based supervision, backpressure, and explicit ack semantics.

## Build Commands

```bash
cabal build all                    # Build everything
cabal test shibuya-core-test       # Run tests
cabal run shibuya-example          # Run example app
nix flake check                    # Run formatting checks
nix fmt                            # Format all files
```

## Before Committing

**IMPORTANT**: Always run `nix fmt` before committing:

```bash
nix fmt
git add <files>
git commit
```

The pre-commit hook runs treefmt which will reject commits with formatting issues. If a commit fails due to formatting, the hook will auto-format the files - just re-stage them with `git add` and commit again.

## Project Structure

```
shibuya-core/           # Main library
  src/Shibuya/
    Core/               # Types, Ack, Ingested, AckHandle, Lease
    Runner/             # Master, Supervised, Processor, Ingester, Metrics, Halt
    Adapter/            # Mock adapter (real adapters live elsewhere)
    App.hs              # runApp entry point
    Handler.hs          # Handler type
    Policy.hs           # Ordering/Concurrency policies
    Prelude.hs          # Common imports
  test/                 # HSpec + QuickCheck tests

shibuya-example/        # Example demonstrating multi-processor setup

docs/
  architecture/         # MESSAGE_FLOW.md, CORE_TYPES.md, METRICS.md
  plans/                # Development plans and design docs
```

## Key Technologies

- **effectful** - Effect system (use `Eff es` for effect stacks)
- **NQE** - Actor supervision (Master, Supervisor, Inbox)
- **streamly** - Stream processing and backpressure
- **generic-lens** - Record access via `#field` labels

## Architecture

```
runApp → Master → [Processor A, Processor B, ...]
                       │
              Adapter.source (stream)
                       │
              Ingester (async) → Bounded Inbox → Processor → Handler
                                                              │
                                                         AckDecision
```

- **Adapter**: Queue-specific stream source + shutdown
- **Handler**: `Ingested es msg -> Eff es AckDecision` (pure intent)
- **AckDecision**: AckOk | AckRetry | AckDeadLetter | AckHalt

## Coding Conventions

### Extensions (enabled by default)
- `OverloadedRecordDot` - Use `.field` syntax
- `OverloadedLabels` - Use `#field` for lens access
- `NoFieldSelectors` - No field accessor functions generated
- `DerivingStrategies` - Always specify deriving strategy

### Formatting (Fourmolu)
- 2-space indentation
- Trailing commas in imports/exports
- Run `nix flake check` to verify

### Patterns
```haskell
-- Effect constraints
someFunction :: (IOE :> es) => Arg -> Eff es Result

-- Record access
metrics.stats.processed      -- OverloadedRecordDot
m & #state .~ newState       -- generic-lens with OverloadedLabels

-- Handler pattern
myHandler :: Handler es MyMessage
myHandler ingested = do
  -- process ingested.envelope.payload
  pure AckOk
```

## Testing

Tests use HSpec with property-based testing via QuickCheck:
```bash
cabal test shibuya-core-test
```

Test modules mirror source structure in `test/Shibuya/`.

## Important Files

| File | Purpose |
|------|---------|
| `Shibuya/App.hs` | Public API: runApp, QueueProcessor |
| `Shibuya/Runner/Supervised.hs` | Core processing loop with metrics |
| `Shibuya/Runner/Master.hs` | Supervisor coordination |
| `Shibuya/Core/Ack.hs` | AckDecision and related types |
| `docs/plans/PRIORITY_1_CRITICAL_FIXES.md` | Current development priorities |

## Development Status

Version 0.1.0.0 (pre-release). Key features implemented:
- Backpressure via bounded inbox
- AckHalt stops processing with halt isolation
- Metrics and introspection
- NQE supervision

Not yet implemented:
- Async/Ahead concurrency modes (Serial only)
- Policy validation enforcement
