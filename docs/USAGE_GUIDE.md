# Shibuya Usage Guide

This guide has been split into focused guides under [`docs/user/`](./user/README.md):

- **[Getting Started](./user/getting-started.md)** - Handlers, ack decisions, runApp, supervision, metrics, graceful shutdown

Adapter-specific guides live with their respective adapter repos:

- [`shibuya-pgmq-adapter`](https://github.com/shinzui/shibuya-pgmq-adapter) — PostgreSQL message queue (setup, dead-letter queues, topic routing, FIFO, prefetching, lease extension, tuning).
- [`shibuya-kafka-adapter`](https://github.com/shinzui/shibuya-kafka-adapter) — Apache Kafka.
