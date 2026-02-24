# PGMQ Adapter: Topic Routing

pgmq 1.11.0 introduced AMQP-like topic-based routing. Messages can be routed to multiple queues using wildcard pattern matching. The Shibuya PGMQ adapter provides convenience functions for managing topic bindings.

## Topic Concepts

### Routing Keys

A routing key is a dot-separated string that identifies a message's topic:

```
orders.created
payments.failed
notifications.email.welcome
```

### Topic Patterns

Patterns use wildcards to match routing keys:

| Wildcard | Meaning | Example Pattern | Matches | Does Not Match |
|----------|---------|-----------------|---------|----------------|
| `*` | Exactly one segment | `logs.*` | `logs.error`, `logs.info` | `logs`, `logs.api.error` |
| `#` | Zero or more segments | `logs.#` | `logs.error`, `logs.api.error` | `logs` |

### Bindings

A binding associates a topic pattern with a queue. When a message is sent with a routing key, it is delivered to all queues whose bindings match.

## Managing Topic Bindings

### Binding Patterns to Queues

```haskell
import Shibuya.Adapter.Pgmq

-- Parse names and patterns
let Right allLogsQueue = parseQueueName "all_logs"
    Right errorLogsQueue = parseQueueName "error_logs"
    Right logsAllPattern = parseTopicPattern "logs.#"
    Right errorPattern = parseTopicPattern "*.error"

-- Bind patterns (idempotent - re-binding is a no-op)
bindQueueTopics allLogsQueue [logsAllPattern]
bindQueueTopics errorLogsQueue [errorPattern]
```

### Unbinding Patterns

```haskell
-- Remove bindings (silent if pattern was not bound)
unbindQueueTopics errorLogsQueue [errorPattern]
```

### Listing Bindings

```haskell
bindings <- listQueueTopicBindings allLogsQueue
-- bindings :: [TopicBinding]
-- Each TopicBinding has: pattern, queueName, boundAt, compiledRegex
```

### Testing Routing

Dry-run to see which queues a routing key would match, without sending any messages:

```haskell
let Right key = parseRoutingKey "logs.error"
matches <- testTopicRouting key
-- matches :: [RoutingMatch]
-- Each RoutingMatch has: pattern, queueName, compiledRegex
```

## Example: Event Fan-Out

Route domain events to multiple consumers based on topic patterns:

```haskell
initTopicBindings :: (Pgmq :> es) => Eff es ()
initTopicBindings = do
  let Right analyticsQueue = parseQueueName "analytics_events"
      Right auditQueue = parseQueueName "audit_log"
      Right orderAlertsQueue = parseQueueName "order_alerts"

  -- Analytics gets everything
  let Right allEvents = parseTopicPattern "#"
  bindQueueTopics analyticsQueue [allEvents]

  -- Audit gets all order and payment events
  let Right orderEvents = parseTopicPattern "orders.#"
      Right paymentEvents = parseTopicPattern "payments.#"
  bindQueueTopics auditQueue [orderEvents, paymentEvents]

  -- Order alerts only gets failures
  let Right orderFailed = parseTopicPattern "orders.failed"
  bindQueueTopics orderAlertsQueue [orderFailed]
```

When a message is sent with routing key `orders.failed`:
- `analytics_events` receives it (matches `#`)
- `audit_log` receives it (matches `orders.#`)
- `order_alerts` receives it (matches `orders.failed`)

## Topic-Routed Dead-Lettering

Topics can be used for dead-letter routing. See [Dead-Letter Queues](./pgmq-dead-letter-queues.md#topic-routed-dlq-pgmq-1110) for details.

## Type Reference

### Parsing Functions

```haskell
parseRoutingKey   :: Text -> Either Text RoutingKey
parseTopicPattern :: Text -> Either Text TopicPattern
```

### Display Functions

```haskell
routingKeyToText   :: RoutingKey -> Text
topicPatternToText :: TopicPattern -> Text
```

### Binding Types

```haskell
data TopicBinding = TopicBinding
  { pattern       :: Text
  , queueName     :: Text
  , boundAt       :: UTCTime
  , compiledRegex :: Text
  }

data RoutingMatch = RoutingMatch
  { pattern       :: Text
  , queueName     :: Text
  , compiledRegex :: Text
  }
```

## Adapter Functions

| Function | Description |
|----------|-------------|
| `bindQueueTopics` | Bind multiple patterns to a queue (idempotent) |
| `unbindQueueTopics` | Unbind multiple patterns from a queue |
| `listQueueTopicBindings` | List all bindings for a queue |
| `testTopicRouting` | Dry-run: show which queues match a routing key |

These are convenience wrappers around the pgmq-effectful operations. For lower-level access, use `Pgmq.Effectful.Effect` directly.
