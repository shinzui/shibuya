# Shibuya User Guides

Guides for using the Shibuya queue processing framework.

## Core Shibuya

- **[Getting Started](./getting-started.md)** - Handlers, ack decisions, runApp, supervision, metrics, graceful shutdown

## PGMQ Adapter

- **[PGMQ Getting Started](./pgmq-getting-started.md)** - Setup, basic consumer, polling strategies
- **[Dead-Letter Queues](./pgmq-dead-letter-queues.md)** - Direct queue and topic-routed dead-lettering
- **[Topic Routing](./pgmq-topic-routing.md)** - AMQP-like topic binding, pattern matching, management (pgmq 1.11.0+)
- **[Advanced PGMQ](./pgmq-advanced.md)** - FIFO ordering, prefetching, lease extension, tuning

## Reference Documentation

- [PGMQ Adapter Configuration Reference](../pgmq-adapter/CONFIGURATION.md)
- [PGMQ Adapter Architecture](../pgmq-adapter/ARCHITECTURE.md)
- [Core Architecture](../architecture/MESSAGE_FLOW.md)
