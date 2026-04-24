# Shibuya User Guides

Guides for using the Shibuya queue processing framework.

## Core Shibuya

- **[Getting Started](./getting-started.md)** - Handlers, ack decisions, runApp, supervision, metrics, graceful shutdown

## Adapters

Adapter-specific user guides live in their own repositories:

- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) — PostgreSQL message queue (getting started, dead-letter queues, topic routing, advanced).
- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter) — Apache Kafka.

## Reference Documentation

- [Core Architecture](../architecture/MESSAGE_FLOW.md)
