# Using hs-opentelemetry with GHC 9.12

This document describes the configuration required to use hs-opentelemetry packages with GHC 9.12.

## Overview

The hs-opentelemetry packages on Hackage don't yet have version bounds that support GHC 9.12 (base 4.21). However, the packages compile fine with GHC 9.12 when using the main branch from GitHub and relaxing some dependency constraints.

## Required Configuration

### 1. Add source-repository-package entries

Add the hs-opentelemetry packages from GitHub to your `cabal.project`:

```cabal
-- hs-opentelemetry from GitHub (main branch for GHC 9.12 support)
source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry
  tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
  subdir: api

source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry
  tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
  subdir: sdk

source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry
  tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
  subdir: otlp

source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry
  tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
  subdir: propagators/w3c
```

### 2. Add allow-newer for proto-lens

The proto-lens packages have upper bounds that exclude GHC 9.12. Add these to your `cabal.project`:

```cabal
-- Allow newer for proto-lens packages (GHC 9.12 support)
allow-newer:
  proto-lens:base,
  proto-lens:ghc-prim,
  proto-lens-runtime:base,
  proto-lens-protobuf-types:base,
  proto-lens-protobuf-types:ghc-prim
```

### 3. Add dependencies to your .cabal file

```cabal
build-depends:
  hs-opentelemetry-api,
  hs-opentelemetry-sdk,
  hs-opentelemetry-otlp,
```

## Usage

### Basic Setup

```haskell
import OpenTelemetry.Trace qualified as OTel
import Control.Exception (bracket)

withTracing :: (OTel.Tracer -> IO a) -> IO a
withTracing action =
  bracket
    OTel.initializeGlobalTracerProvider
    OTel.shutdownTracerProvider
    $ \provider -> do
      let tracer = OTel.makeTracer provider instrumentationLib OTel.tracerOptions
      action tracer
  where
    instrumentationLib = OTel.InstrumentationLibrary
      { OTel.libraryName = "my-service"
      , OTel.libraryVersion = "1.0.0"
      , OTel.librarySchemaUrl = ""
      , OTel.libraryAttributes = emptyAttributes
      }
```

### Environment Variables

The SDK reads configuration from environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service name for traces | - |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL | `http://localhost:4318` |
| `OTEL_TRACES_EXPORTER` | Exporter type | `otlp` |
| `OTEL_SDK_DISABLED` | Disable SDK | `false` |

### OTLP Protocol

The hs-opentelemetry OTLP exporter uses **HTTP/protobuf** protocol (not gRPC):

- Default port: **4318** (HTTP)
- Not supported: 4317 (gRPC)

When using Jaeger, ensure port 4318 is exposed:

```bash
# Start Jaeger with OTLP support
jaeger --collector.otlp.enabled=true

# Or with Docker
docker run -d \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

Example environment configuration:

```bash
export OTEL_SERVICE_NAME=my-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

## Verification

After setup, verify traces appear in Jaeger:

```bash
# Check services
curl -s 'http://localhost:16686/api/services' | jq '.data'

# Check traces
curl -s 'http://localhost:16686/api/traces?service=my-service&limit=5' | jq '.data | length'
```

## Known Limitations

1. **gRPC not supported**: The OTLP exporter only supports HTTP/protobuf, not gRPC
2. **proto-lens bounds**: Requires `allow-newer` until proto-lens releases GHC 9.12 support
3. **Hackage versions**: Must use GitHub main branch until new versions are released

## References

- [hs-opentelemetry GitHub](https://github.com/iand675/hs-opentelemetry)
- [OpenTelemetry OTLP Exporter Configuration](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/)
- [Jaeger OTLP Support](https://www.jaegertracing.io/docs/latest/apis/#opentelemetry-protocol-otlp)
