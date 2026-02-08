# shibuya-pgmq-example

A real-world example demonstrating Shibuya queue processing with PGMQ adapter and OpenTelemetry tracing.

## Overview

This package provides two executables:

- **shibuya-pgmq-simulator** - CLI tool to enqueue test messages
- **shibuya-pgmq-consumer** - Multi-processor consumer with different configurations per queue

## Queue Configuration

| Queue | Batch | Polling | Features | Handler Behavior |
|-------|-------|---------|----------|------------------|
| orders | 5 | Standard (1s) | DLQ | 10% random retry, JSON validation |
| payments | 1 | Long (10s) | FIFO + DLQ | DLQs negative/large amounts |
| notifications | 20 | Standard (0.5s) | High throughput | Fast processing, no DLQ |

## Prerequisites

- PostgreSQL with PGMQ extension installed
- (Optional) Jaeger for distributed tracing

## Quick Start

### 1. Start PostgreSQL with PGMQ

```bash
# Using Docker
docker run -d \
  --name pgmq \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  quay.io/tembo/pgmq-pg:latest

# Create database
psql -h localhost -U postgres -c "CREATE DATABASE pgmq;"
```

### 2. Start Jaeger (Optional)

```bash
docker run -d \
  --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4317:4317 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

Jaeger UI will be available at http://localhost:16686

### 3. Run the Consumer

```bash
export DATABASE_URL="postgres://postgres:postgres@localhost:5432/pgmq"

# Without tracing
cabal run shibuya-pgmq-consumer

# With tracing enabled
export OTEL_TRACING_ENABLED=true
export OTEL_SERVICE_NAME=shibuya-pgmq-example
cabal run shibuya-pgmq-consumer
```

### 4. Run the Simulator

```bash
export DATABASE_URL="postgres://postgres:postgres@localhost:5432/pgmq"

# Send 100 orders
cabal run shibuya-pgmq-simulator -- --queue orders --count 100

# Send 50 payments at 10 msg/s
cabal run shibuya-pgmq-simulator -- --queue payments --count 50 --rate 10

# Send 1000 notifications in batches of 50
cabal run shibuya-pgmq-simulator -- --queue notifications --count 1000 --batch-size 50
```

## Environment Variables

### Consumer

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | (required) |
| `OTEL_TRACING_ENABLED` | Enable OpenTelemetry tracing | `false` |
| `OTEL_SERVICE_NAME` | Service name for traces | `shibuya-pgmq-example` |
| `METRICS_PORT` | HTTP port for metrics server | `9090` |

### Simulator

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | (required) |

### Simulator CLI Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `--queue` | Target queue: orders, payments, notifications | orders |
| `--count` | Number of messages to send | 100 |
| `--rate` | Messages per second | 50 |
| `--batch-size` | Batch size for sending | 10 |

## OpenTelemetry Setup with Jaeger

### Docker Compose Setup

Create a `docker-compose.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: quay.io/tembo/pgmq-pg:latest
    environment:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: pgmq
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  jaeger:
    image: jaegertracing/all-in-one:latest
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16686:16686"  # Jaeger UI
      - "4317:4317"    # OTLP gRPC
      - "4318:4318"    # OTLP HTTP
```

Start the services:

```bash
docker-compose up -d
```

### Running with Tracing

```bash
# Set connection and tracing environment
export DATABASE_URL="postgres://postgres:postgres@localhost:5432/pgmq"
export OTEL_TRACING_ENABLED=true
export OTEL_SERVICE_NAME=shibuya-pgmq-example
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318  # HTTP/protobuf

# Start consumer
cabal run shibuya-pgmq-consumer

# In another terminal, send messages
export DATABASE_URL="postgres://postgres:postgres@localhost:5432/pgmq"
cabal run shibuya-pgmq-simulator -- --queue orders --count 10
```

View traces at http://localhost:16686

The OTLP exporter uses HTTP/protobuf protocol (port 4318), not gRPC (port 4317).

### Known Issues

**Prefetch Configuration**: The prefetch feature (`prefetchConfig`) is currently disabled in this example due to an STM deadlock issue with streamly's `parBuffered` operator. When enabled, the processor thread blocks indefinitely in an STM transaction. The high-throughput notifications queue uses standard polling with a large batch size as a workaround. See `docs/plans/PREFETCH_STM_BUG.md` for details.

## Metrics Endpoints

When the consumer is running, metrics are available at:

| Endpoint | Description |
|----------|-------------|
| `http://localhost:9090/metrics` | JSON metrics for all processors |
| `http://localhost:9090/metrics/prometheus` | Prometheus-format metrics |
| `http://localhost:9090/health` | Detailed health status |
| `http://localhost:9090/health/live` | Liveness probe (Kubernetes) |
| `http://localhost:9090/health/ready` | Readiness probe (Kubernetes) |
| `ws://localhost:9090/ws` | WebSocket for real-time updates |

## Message Formats

### Order

```json
{
  "orderId": "ORD-123",
  "customerId": "CUST-456",
  "items": [
    {
      "productId": "PROD-789",
      "productName": "Widget",
      "quantity": 2,
      "unitPrice": 29.99
    }
  ],
  "totalAmount": 59.98,
  "status": "Pending"
}
```

### Payment

```json
{
  "paymentId": "PAY-123",
  "orderId": "ORD-123",
  "customerId": "CUST-456",
  "amount": 59.98,
  "currency": "USD",
  "method": "CreditCard",
  "status": "PaymentPending"
}
```

Payments use FIFO ordering by `customerId` via the `x-pgmq-group` header.

### Notification

```json
{
  "notificationId": "NOTIF-123",
  "userId": "USER-456",
  "notificationType": "Email",
  "title": "Order Confirmation",
  "body": "Your order has been confirmed.",
  "priority": "Normal"
}
```

## Handler Behaviors

### Orders Handler
- Validates JSON structure (requires `orderId` field)
- 10% random retry simulation for testing retry logic
- Invalid JSON is sent to `dlq_orders`

### Payments Handler
- Validates payment amount
- Negative amounts → DLQ (invalid payload)
- Amounts > $10,000 → DLQ (requires manual review)
- FIFO processing by customer ID

### Notifications Handler
- Fast processing (1ms simulated delay)
- No DLQ - invalid notifications are acknowledged
- High throughput with prefetching enabled
