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
| `docs/plans/archive/PRIORITY_1_CRITICAL_FIXES.md` | Historical development priorities (archived) |

## Local Development Environment

### PostgreSQL

The project uses a local PostgreSQL instance with Unix sockets (no TCP). The nix devShell sets up:

```bash
PGHOST="$PWD/db"           # Socket directory
PGDATA="$PGHOST/db"        # Data directory
PGDATABASE=shibuya         # Database name
```

**Connection string format:**
```bash
# URL-encoded Unix socket path
DATABASE_URL="postgresql://%2FUsers%2F...%2Fshibuya%2Fdb/shibuya"

# Or generate it:
DATABASE_URL="postgresql://$(jq -rn --arg x $PWD/db '$x|@uri')/shibuya"
```

**Starting PostgreSQL:**
```bash
pg_ctl start -l $PGHOST/postgres.log
```

**Testing connection:**
```bash
psql -h $PWD/db -d shibuya -c "SELECT 1"
```

### Jaeger (Tracing)

Jaeger binary location: `~/.local/bin/jaeger`

**Starting Jaeger:**
```bash
~/.local/bin/jaeger > /tmp/jaeger.log 2>&1 &
```

**Ports:**
- UI: http://127.0.0.1:16686
- OTLP HTTP: http://127.0.0.1:4318 (used by hs-opentelemetry)

**Environment variables for tracing:**
```bash
OTEL_TRACING_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
OTEL_SERVICE_NAME="shibuya-consumer"  # or shibuya-simulator
```

**Checking traces via API:**
```bash
# List services
curl -s "http://127.0.0.1:16686/api/services" | jq '.data[]'

# Get traces for a service
curl -s "http://127.0.0.1:16686/api/traces?service=shibuya-consumer&limit=5" | jq
```

## Development Status

Version 0.1.0.0 — published on [Hackage](https://hackage.haskell.org/package/shibuya-core-0.1.0.0) (pre-release). Key features implemented:
- Backpressure via bounded inbox
- AckHalt stops processing with halt isolation
- Metrics and introspection
- NQE supervision
- Serial/Ahead/Async concurrency modes
- Policy validation enforcement (StrictInOrder requires Serial)
- OpenTelemetry tracing integration
- Graceful shutdown with drain timeout
