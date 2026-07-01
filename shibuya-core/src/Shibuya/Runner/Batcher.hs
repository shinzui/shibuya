-- | Batch accumulation engine.
--
-- Groups a stream of individual 'Ingested' messages into batches by batch key.
-- A batch is emitted when it reaches the configured size, when its per-key
-- timeout elapses, or when the input ends / the processor drains. This module
-- only /regroups/ messages: it never runs a handler and never touches an
-- 'AckHandle'. Its correctness property is message conservation — every input
-- message appears in exactly one emitted batch, and per batch key arrival order
-- is preserved.
--
-- The accumulation logic is a pure, deterministic core (see 'stepArrival',
-- 'stepTick', 'stepFlush') that takes the current time as an argument, so it is
-- property-tested with no threads or wall-clock. 'runBatcher' is a thin IO
-- wrapper that drives the core from a background consumer and a single timeout
-- ticker, buffering results in a bounded queue for backpressure.
module Shibuya.Runner.Batcher
  ( -- * Pure accumulation core
    Accum (..),
    BatcherState (..),
    emptyBatcherState,
    ReadyBatch,
    stepArrival,
    stepTick,
    stepFlush,

    -- * IO engine
    runBatcher,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( TBQueue,
    TVar,
    atomically,
    isEmptyTBQueue,
    newTBQueueIO,
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    tryReadTBQueue,
    writeTBQueue,
    writeTVar,
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Time (diffUTCTime)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchKey, BatchTrigger (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Prelude
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO (finally)
import UnliftIO.Async (async, cancel)

-- | In-progress state for one batch key.
data Accum es msg = Accum
  { -- | Messages accumulated so far, newest first (reversed arrival order).
    messages :: ![Ingested es msg],
    -- | How many messages are buffered (== length of 'messages'). Always >= 1.
    count :: !Int,
    -- | When the first message for this key arrived (drives the timeout).
    firstArrivalAt :: !UTCTime,
    -- | Partition of the first message, copied into the emitted 'BatchInfo'.
    partition0 :: !(Maybe Text)
  }

-- | The engine's memory: one 'Accum' per active batch key.
newtype BatcherState es msg = BatcherState
  { accums :: Map BatchKey (Accum es msg)
  }

-- | An empty state with no groups in progress.
emptyBatcherState :: BatcherState es msg
emptyBatcherState = BatcherState Map.empty

-- | A finished group ready to hand downstream: metadata plus its messages in
-- arrival order. This is the exact value the execution stage (EP-18) consumes.
type ReadyBatch es msg = (BatchInfo, NonEmpty (Ingested es msg))

-- | Build a ReadyBatch from a completed accumulator. Reverses the buffered
-- messages back into arrival order; safe because count >= 1.
emitAccum :: BatchKey -> BatchTrigger -> Accum es msg -> ReadyBatch es msg
emitAccum key trig acc =
  ( BatchInfo
      { batchKey = key,
        size = acc.count,
        trigger = trig,
        partition = acc.partition0
      },
    NE.fromList (reverse acc.messages)
  )

-- | Fold one arriving message into the state. Emits a size-triggered batch iff
-- the message fills its key's accumulator to batchSize.
stepArrival ::
  BatchConfig es msg ->
  UTCTime ->
  Ingested es msg ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepArrival cfg now ing (BatcherState accums) =
  let key = cfg.batchKey ing.envelope
   in case Map.lookup key accums of
        Nothing ->
          let acc =
                Accum
                  { messages = [ing],
                    count = 1,
                    firstArrivalAt = now,
                    partition0 = ing.envelope.partition
                  }
           in if cfg.batchSize <= 1
                then (BatcherState (Map.delete key accums), [emitAccum key TriggerSize acc])
                else (BatcherState (Map.insert key acc accums), [])
        Just acc ->
          let acc' = acc {messages = ing : acc.messages, count = acc.count + 1}
           in if acc'.count >= cfg.batchSize
                then (BatcherState (Map.delete key accums), [emitAccum key TriggerSize acc'])
                else (BatcherState (Map.insert key acc' accums), [])

-- | Emit every accumulator whose timeout has elapsed as of 'now'.
stepTick ::
  BatchConfig es msg ->
  UTCTime ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepTick cfg now (BatcherState accums) =
  let timedOut :: Accum es msg -> Bool
      timedOut acc = diffUTCTime now acc.firstArrivalAt >= cfg.batchTimeout
      (ripe, keep) = Map.partition timedOut accums
      ready = [emitAccum k TriggerTimeout acc | (k, acc) <- Map.toList ripe]
   in (BatcherState keep, ready)

-- | Emit all remaining accumulators (end-of-input / drain). Leaves the state empty.
stepFlush ::
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepFlush (BatcherState accums) =
  (emptyBatcherState, [emitAccum k TriggerFlush acc | (k, acc) <- Map.toList accums])

-- | Run one pure step under the shared mutex, then push each emitted batch onto
-- the bounded output queue (blocking when it is full, which is how backpressure
-- propagates). Serializing state-transition + hand-off keeps a size-emit and a
-- timeout-emit for the same key from both firing (no double-emit) and preserves
-- the order in which batches reach the queue.
emitStep ::
  MVar () ->
  IORef (BatcherState es msg) ->
  TBQueue (ReadyBatch es msg) ->
  (BatcherState es msg -> (BatcherState es msg, [ReadyBatch es msg])) ->
  IO ()
emitStep lock stateRef outQ step =
  withMVar lock $ \_ -> do
    ready <- atomicModifyIORef' stateRef step
    mapM_ (atomically . writeTBQueue outQ) ready

-- | Convert a 'NominalDiffTime' (seconds) into whole microseconds for
-- 'threadDelay', clamped to at least 1 so a misconfiguration cannot spin.
nominalToMicros :: NominalDiffTime -> Int
nominalToMicros d = max 1 (round (realToFrac d * 1e6 :: Double))

-- | Group a stream of individual messages into a stream of batches.
--
-- @outputCapacity@ bounds how many finished batches may sit un-consumed (>= 1);
-- when full, the engine stalls, propagating backpressure upstream. @cfg@ carries
-- the size, timeout, key function, and tick interval. The @es@/@msg@ parameters
-- are phantom to the engine (it never runs an effect or acks a message).
runBatcher ::
  Natural ->
  BatchConfig es msg ->
  Stream IO (Ingested es msg) ->
  Stream IO (ReadyBatch es msg)
runBatcher outputCapacity cfg input =
  Stream.bracketIO acquire release consume
  where
    tickMicros = nominalToMicros (fromMaybe cfg.batchTimeout cfg.tickInterval)

    acquire = do
      lock <- newMVar ()
      stateRef <- newIORef emptyBatcherState
      outQ <- newTBQueueIO outputCapacity
      doneVar <- newTVarIO False

      let onArrival ing = do
            now <- getCurrentTime
            emitStep lock stateRef outQ (stepArrival cfg now ing)

          -- Consume the whole input, flush the remainder, then mark done.
          -- 'finally' guarantees doneVar is set even if the input stream throws,
          -- so the output stream below always terminates. Propagating a consumer
          -- failure to the caller is the integration plan's concern (EP-19), just
          -- as the per-message loop polls its ingester async.
          consumer =
            ( do
                Stream.fold Fold.drain (Stream.mapM onArrival input)
                emitStep lock stateRef outQ stepFlush
            )
              `finally` atomically (writeTVar doneVar True)

          tickerLoop = do
            threadDelay tickMicros
            done <- readTVarIO doneVar
            if done
              then pure ()
              else do
                now <- getCurrentTime
                emitStep lock stateRef outQ (stepTick cfg now)
                tickerLoop

      consumerA <- async consumer
      tickerA <- async tickerLoop
      pure (outQ, doneVar, consumerA, tickerA)

    release (_outQ, _doneVar, consumerA, tickerA) = do
      cancel tickerA
      cancel consumerA

    consume (outQ, doneVar, _consumerA, _tickerA) = drainQueue outQ doneVar

-- | Stream finished batches out of the bounded queue, ending when the consumer
-- has flushed everything (doneVar) and the queue has drained.
drainQueue ::
  TBQueue (ReadyBatch es msg) ->
  TVar Bool ->
  Stream IO (ReadyBatch es msg)
drainQueue outQ doneVar = Stream.unfoldrM step ()
  where
    step _ = atomically $ do
      mReady <- tryReadTBQueue outQ
      case mReady of
        Just rb -> pure (Just (rb, ()))
        Nothing -> do
          done <- readTVar doneVar
          qEmpty <- isEmptyTBQueue outQ
          if done && qEmpty
            then pure Nothing
            else retry
