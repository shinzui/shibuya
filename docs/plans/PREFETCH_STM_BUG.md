# Prefetch STM Deadlock Bug

## Summary

The prefetch feature in `shibuya-pgmq-adapter` causes an STM deadlock when used with effectful. When `prefetchConfig` is enabled, the processor thread blocks indefinitely with the error:

```
ExceptionInLinkedThread (ThreadId 25) thread blocked indefinitely in an STM transaction
```

## Reproduction

1. Enable prefetch in an adapter config:
```haskell
notificationsAdapterConfig =
  (Pgmq.defaultConfig notificationsQueueName)
    { prefetchConfig = Just defaultPrefetchConfig
    , ...
    }
```

2. Start the consumer with this adapter
3. The processor registers with the Master but the worker thread deadlocks

## Technical Details

### Code Path

1. `pgmqAdapter` selects the source based on `prefetchConfig`:
   - `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs:142-150`

2. When prefetch is enabled, it uses `pgmqSourceWithPrefetch`:
   - `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:352-359`

3. Which calls `pgmqChunksPrefetch` using streamly's `parBuffered`:
   - `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:318-320`
   ```haskell
   pgmqChunksPrefetch prefetchConfig config =
     pgmqChunks config
       & StreamP.parBuffered prefetchConfig
   ```

4. The stream is consumed in `runIngesterWithMetrics`:
   - `shibuya-core/src/Shibuya/Runner/Ingester.hs:48-60`

5. Which runs inside an async spawned by `runSupervised` using `withEffToIO`:
   - `shibuya-core/src/Shibuya/Runner/Supervised.hs:158-166`

### Hypothesis

`StreamP.parBuffered` from streamly uses STM internally to coordinate concurrent prefetch workers. When combined with effectful's `withEffToIO (ConcUnlift Persistent Unlimited)`, the STM transactions may not have access to the correct thread-local state, causing the deadlock.

Possible causes:
1. `parBuffered` forks worker threads that don't inherit the effectful unlift context
2. STM TVars created in one unlift context aren't visible in another
3. The combination of NQE's `addChild` + effectful's unlift + streamly's `parBuffered` creates a thread coordination issue

## Workaround

Disable prefetch by setting `prefetchConfig = Nothing`. Use larger batch sizes instead for high-throughput queues.

## Investigation Steps

1. Create a minimal reproduction without the full consumer setup
2. Test `parBuffered` with effectful in isolation
3. Check if the issue is specific to the `ConcUnlift Persistent Unlimited` strategy
4. Review streamly's `parBuffered` implementation for STM usage patterns
5. Consider alternative prefetch implementations that don't use `parBuffered`

## Affected Files

- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`
- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`
- `shibuya-core/src/Shibuya/Runner/Supervised.hs`
- `shibuya-core/src/Shibuya/Runner/Ingester.hs`

## Related

- streamly `parBuffered`: https://hackage.haskell.org/package/streamly-core/docs/Streamly-Data-Stream-Prelude.html#v:parBuffered
- effectful unlift strategies: https://hackage.haskell.org/package/effectful-core/docs/Effectful.html#t:UnliftStrategy
