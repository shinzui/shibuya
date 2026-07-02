-- | Shared resilient finalization for framework-owned ack paths.
--
-- Both single-message and batch processing call adapter-provided
-- 'AckHandle.finalize' through this module. A transient finalizer exception is
-- retried with the fixed schedule below; each retry uses the same already
-- resolved 'AckDecision'.
module Shibuya.Runner.Finalize
  ( finalizeRetryDelaysMicros,
    finalizeWithRetry,
  )
where

import Effectful (Eff, IOE, liftIO, (:>))
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Telemetry.Effect (Tracing, recordException)
import UnliftIO (SomeException, catchAny)
import UnliftIO.Concurrent (threadDelay)

-- | Retry delays, in microseconds, used after failed finalization attempts.
finalizeRetryDelaysMicros :: [Int]
finalizeRetryDelaysMicros = [10_000, 50_000, 250_000]

-- | Call a message finalizer until it succeeds or the bounded retry budget is
-- exhausted. The resolved decision is never recomputed between attempts.
finalizeWithRetry ::
  (IOE :> es, Tracing :> es) =>
  OTel.Span ->
  Ingested es msg ->
  AckDecision ->
  Eff es (Either SomeException ())
finalizeWithRetry traceSpan ingested decision = go finalizeRetryDelaysMicros
  where
    go delays =
      catchAny
        (Right <$> ingested.ack.finalize decision)
        ( \ex -> do
            recordException traceSpan ex
            case delays of
              [] -> pure (Left ex)
              delay : rest -> do
                liftIO $ threadDelay delay
                go rest
        )
