# PGMQ Adapter: Dead-Letter Queues

This guide covers configuring dead-letter queue (DLQ) handling, including the topic-based routing option introduced in pgmq 1.11.0.

## When Messages Are Dead-Lettered

A message is dead-lettered when:

- `readCount` exceeds `maxRetries` (automatic, before handler sees the message)
- Handler returns `AckDeadLetter (InvalidPayload "...")`
- Handler returns `AckDeadLetter (PoisonPill "...")`
- Handler returns `AckDeadLetter MaxRetriesExceeded`

## Without DLQ Configuration

When `deadLetterConfig = Nothing` (the default), dead-lettered messages are archived using pgmq's `archiveMessage`. They remain in the archive table but are not sent to a separate queue.

## Direct Queue DLQ

Send dead-lettered messages to a specific queue:

```haskell
let Right dlqName = parseQueueName "orders_dlq"

let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ directDeadLetter dlqName True,
        maxRetries = 3
      }
```

The `directDeadLetter` smart constructor takes:
- `QueueName` - the target DLQ
- `Bool` - whether to include original message metadata

## Topic-Routed DLQ (pgmq 1.11.0+)

Route dead-lettered messages via topic pattern matching, allowing fan-out to multiple DLQ consumers:

```haskell
let Right routingKey = parseRoutingKey "dlq.orders.failed"

let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True,
        maxRetries = 3
      }
```

Messages are sent using `pgmq.send_topic` with the given routing key. Any queues with matching topic bindings will receive the dead-lettered message.

### Example: Fan-Out DLQ with Topics

```haskell
-- Set up topic bindings (one-time, e.g., during application init)
let Right allDlqPattern = parseTopicPattern "dlq.#"
    Right ordersDlqPattern = parseTopicPattern "dlq.orders.*"
    Right allDlqQueue = parseQueueName "all_dlq"
    Right ordersDlqQueue = parseQueueName "orders_dlq"

bindQueueTopics allDlqQueue [allDlqPattern]
bindQueueTopics ordersDlqQueue [ordersDlqPattern]

-- Configure the adapter with topic-routed dead-lettering
let Right routingKey = parseRoutingKey "dlq.orders.failed"
let config = (defaultConfig ordersQueue)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True
      }
```

With this setup, when an order message is dead-lettered:
- `dlq.orders.failed` matches `dlq.#` -> delivered to `all_dlq`
- `dlq.orders.failed` matches `dlq.orders.*` -> delivered to `orders_dlq`

Both queues receive the dead-lettered message.

## DLQ Message Format

### With `includeMetadata = True`

```json
{
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded",
  "original_message_id": 456,
  "original_enqueued_at": "2024-01-15T10:30:00Z",
  "read_count": 4,
  "original_headers": { "x-pgmq-group": "customer-1" }
}
```

### With `includeMetadata = False`

```json
{
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded"
}
```

### Dead-Letter Reasons

| Reason | Description |
|--------|-------------|
| `max_retries_exceeded` | Message exceeded `maxRetries` |
| `poison_pill: <text>` | Handler returned `AckDeadLetter (PoisonPill text)` |
| `invalid_payload: <text>` | Handler returned `AckDeadLetter (InvalidPayload text)` |

## Header Preservation

When the original message has headers (e.g., `x-pgmq-group` for FIFO), the adapter preserves them on the DLQ message. This applies to both direct queue and topic-routed dead-lettering.

## DeadLetterTarget Type

The `DeadLetterTarget` sum type controls where dead-lettered messages are sent:

```haskell
data DeadLetterTarget
  = DirectQueue !QueueName   -- Send to a specific queue
  | TopicRoute !RoutingKey   -- Route via topic pattern matching (pgmq 1.11.0+)
```

Smart constructors:

```haskell
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig
topicDeadLetter  :: RoutingKey -> Bool -> DeadLetterConfig
```

## Choosing Between Direct and Topic Routing

| Scenario | Recommendation |
|----------|---------------|
| Single DLQ per source queue | `directDeadLetter` |
| Multiple consumers need DLQ messages | `topicDeadLetter` |
| Centralized DLQ monitoring | `topicDeadLetter` with `dlq.#` binding |
| Simple setup, no pgmq 1.11.0 | `directDeadLetter` |
| Per-service DLQ routing | `topicDeadLetter` with service-specific patterns |
