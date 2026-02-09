# Testing with Local Jaeger

This document describes how to run Jaeger locally for testing OpenTelemetry traces.

## Starting Jaeger

Download Jaeger from [jaegertracing/jaeger releases](https://github.com/jaegertracing/jaeger/releases) and run:

```bash
# Start with OTLP collector enabled
jaeger --collector.otlp.enabled=true
```

Or if you have it in a custom location:

```bash
~/.local/bin/jaeger --collector.otlp.enabled=true
```

## Jaeger Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 16686 | HTTP | Jaeger UI |
| 4317 | gRPC | OTLP gRPC receiver |
| 4318 | HTTP | OTLP HTTP receiver |

**Note**: The hs-opentelemetry OTLP exporter uses HTTP/protobuf (port 4318), not gRPC.

## Testing shibuya-pgmq-example

### 1. Start PostgreSQL

```bash
# Using process-compose (from project root)
just process-up
```

### 2. Start Jaeger

```bash
jaeger --collector.otlp.enabled=true
```

### 3. Start the Consumer with Tracing

```bash
export DATABASE_URL="postgres:///shibuya?host=$PGHOST"
export OTEL_TRACING_ENABLED=true
export OTEL_SERVICE_NAME=shibuya-pgmq-example
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318

cabal run shibuya-pgmq-consumer
```

### 4. Send Test Messages

In another terminal:

```bash
export DATABASE_URL="postgres:///shibuya?host=$PGHOST"

# Send orders
cabal run shibuya-pgmq-simulator -- --queue orders --count 10

# Send payments
cabal run shibuya-pgmq-simulator -- --queue payments --count 5

# Send notifications
cabal run shibuya-pgmq-simulator -- --queue notifications --count 20
```

### 5. View Traces

Open http://localhost:16686 in your browser.

1. Select "shibuya-pgmq-example" from the Service dropdown
2. Click "Find Traces"
3. Click on a trace to see span details

## Verifying Traces via API

### Check registered services

```bash
curl -s 'http://localhost:16686/api/services' | jq '.data'
```

Expected output:
```json
[
  "shibuya-pgmq-example",
  "jaeger"
]
```

### Check trace count

```bash
curl -s 'http://localhost:16686/api/traces?service=shibuya-pgmq-example&limit=10' | jq '.data | length'
```

### View trace details

```bash
curl -s 'http://localhost:16686/api/traces?service=shibuya-pgmq-example&limit=1' | jq '.data[0].spans[0]'
```

Expected span attributes:
- `operationName`: "shibuya.process.message"
- `messaging.system`: "shibuya"
- `messaging.message.id`: message ID
- `shibuya.ack.decision`: "ack_ok", "ack_retry", or "ack_dead_letter"
- `shibuya.inflight.count`: current in-flight messages
- `shibuya.inflight.max`: max concurrent messages

## Troubleshooting

### No traces appearing

1. **Check service is registered**:
   ```bash
   curl -s 'http://localhost:16686/api/services' | jq '.data'
   ```

2. **Verify OTLP endpoint**: Ensure you're using port 4318 (HTTP), not 4317 (gRPC)

3. **Check Jaeger is listening**:
   ```bash
   lsof -i :4318
   ```

4. **Verify consumer health**:
   ```bash
   curl -s http://localhost:9090/health | jq '.status'
   ```

### Traces not exporting

1. **Check OTEL_TRACING_ENABLED**: Must be `true`
2. **Check endpoint URL**: Must include `http://` prefix
3. **Verify messages are being processed**:
   ```bash
   curl -s http://localhost:9090/health | jq '.processors'
   ```

### Connection refused

Ensure Jaeger is running with OTLP enabled:
```bash
# Check if Jaeger process is running
pgrep -f jaeger

# Check if port 4318 is listening
lsof -i :4318
```

## Cleanup

```bash
# Stop Jaeger
pkill -f jaeger

# Stop consumer
pkill -f shibuya-pgmq-consumer
```
