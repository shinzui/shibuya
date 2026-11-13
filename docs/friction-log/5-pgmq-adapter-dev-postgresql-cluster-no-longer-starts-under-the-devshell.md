---
type: Friction Entry
title: "PGMQ adapter dev PostgreSQL cluster no longer starts under the devShell"
description: "The shibuya-pgmq-adapter devShell now provides PostgreSQL 18 while its db/db cluster was initialised by an older major, so pg_ctl refuses it and the benchmark and example runs needed a throwaway cluster."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T16:26:30Z"
frictionId: FRIC-5
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/shibuya"
affects: "mori://shinzui/shibuya-pgmq-adapter"
plan: "docs/plans/58-adopt-trace-correlation-in-the-pgmq-adapter.md"
workaround: "initdb a throwaway cluster in the session scratchpad on 127.0.0.1:55432 (unix sockets disabled because the scratchpad path exceeds the socket path limit) and point DATABASE_URL / PG_CONNECTION_STRING at it; the existing db/db cluster was left untouched"
---
# PGMQ adapter dev PostgreSQL cluster no longer starts under the devShell

## Attempted

Start the adapter's local PostgreSQL with pg_ctl inside nix develop to run the DB benchmark and the Jaeger example check

## Encountered

pg_ctl start failed immediately and no socket appeared

```text
waiting for server to start....pg_ctl: control file appears to be corrupt
```

## Workaround

initdb a throwaway cluster in the session scratchpad on 127.0.0.1:55432 (unix sockets disabled because the scratchpad path exceeds the socket path limit) and point DATABASE_URL / PG_CONNECTION_STRING at it; the existing db/db cluster was left untouched
