-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Batch accumulation engine.
--
-- Groups a stream of individual ingested messages into batches by batch key.
-- A batch is emitted when it reaches the configured size, when its per-key
-- timeout elapses, or when the input ends / the processor drains. This module
-- only /regroups/ messages: it never runs a handler and never touches an
-- an ack handle. Its correctness property is message conservation — every input
-- message appears in exactly one emitted batch, and per batch key arrival order
-- is preserved.
--
-- The accumulation logic is a pure, deterministic core (see 'stepArrival',
-- 'stepTick', 'stepFlush') that takes the current time as an argument, so it is
-- property-tested with no threads or wall-clock. 'runBatcher' is a thin IO
-- wrapper that drives the core from a background consumer and a single timeout
-- ticker, buffering results in a bounded queue for backpressure.
module Shibuya.Internal.Runner.Batcher
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
import Control.Concurrent.STM
  ( TVar,
    atomically,
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Control.Monad (when)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq (..), (><))
import Data.Sequence qualified as Seq
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Shibuya.Batch (BatchConfig (..), BatchInfo (..), BatchKey, BatchTrigger (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Prelude
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO (finally, throwIO)
import UnliftIO.Async (Async, async, cancel, waitCatch)

-- | In-progress state for one batch key.
data Accum es msg = Accum
  { -- | Messages accumulated so far, newest first (reversed arrival order).
    messages :: ![Ingested es msg],
    -- | How many messages are buffered (== length of 'messages'). Always >= 1.
    count :: !Int,
    -- | When the first message for this key arrived (drives the timeout).
    firstArrivalAt :: !Word64,
    -- | Partition of the first message, copied into the emitted batch info.
    partition0 :: !(Maybe Text)
  }

-- | The engine's memory: one accumulator per active batch key.
newtype BatcherState es msg = BatcherState
  { accums :: Map BatchKey (Accum es msg)
  }

-- | An empty state with no groups in progress.
emptyBatcherState :: BatcherState es msg
emptyBatcherState = BatcherState Map.empty

-- | A finished group ready to hand downstream: metadata plus its messages in
-- arrival order. This is the exact value the execution stage (EP-18) consumes.
type ReadyBatch es msg = (BatchInfo, NonEmpty (Ingested es msg))

data DrainStep es msg
  = DrainReady !(ReadyBatch es msg)
  | DrainDone

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
  Word64 ->
  Ingested es msg ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepArrival cfg now ing (BatcherState accums) =
  let key = cfg.batchKey ing.envelope
      (ready, accums') = Map.alterF update key accums
   in (BatcherState accums', ready)
  where
    update Nothing =
      let acc =
            Accum
              { messages = [ing],
                count = 1,
                firstArrivalAt = now,
                partition0 = ing.envelope.partition
              }
       in if cfg.batchSize <= 1
            then ([emitAccum (cfg.batchKey ing.envelope) TriggerSize acc], Nothing)
            else ([], Just acc)
    update (Just acc) =
      let key = cfg.batchKey ing.envelope
          acc' = acc {messages = ing : acc.messages, count = acc.count + 1}
       in if acc'.count >= cfg.batchSize
            then ([emitAccum key TriggerSize acc'], Nothing)
            else ([], Just acc')

-- | Emit every accumulator whose timeout has elapsed as of the supplied time.
stepTick ::
  BatchConfig es msg ->
  Word64 ->
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepTick cfg now (BatcherState accums) =
  let timedOut :: Accum es msg -> Bool
      timedOut acc = now >= acc.firstArrivalAt && now - acc.firstArrivalAt >= nominalToNanos cfg.batchTimeout
      (ripe, keep) = Map.partition timedOut accums
      ready = [emitAccum k TriggerTimeout acc | (k, acc) <- Map.toList ripe]
   in (BatcherState keep, ready)

-- | Emit all remaining accumulators (end-of-input / drain). Leaves the state empty.
stepFlush ::
  BatcherState es msg ->
  (BatcherState es msg, [ReadyBatch es msg])
stepFlush (BatcherState accums) =
  (emptyBatcherState, [emitAccum k TriggerFlush acc | (k, acc) <- Map.toList accums])

-- | Run one pure step in the same STM transaction that appends emitted batches
-- to the pending output buffer. Admission waits while the pending buffer is at
-- capacity, so backpressure blocks without holding a separate mutex. One step
-- may append a burst larger than the remaining capacity; the bound is therefore
-- capacity plus one step's burst.
emitStep ::
  TVar (BatcherState es msg, Seq (ReadyBatch es msg)) ->
  Int ->
  (BatcherState es msg -> (BatcherState es msg, [ReadyBatch es msg])) ->
  IO ()
emitStep stateVar capacity step =
  atomically $ do
    (state, pending) <- readTVar stateVar
    when (Seq.length pending >= capacity) retry
    let (state', ready) = step state
    writeTVar stateVar (state', pending >< Seq.fromList ready)

-- | Convert a 'NominalDiffTime' (seconds) into whole microseconds for
-- 'threadDelay', clamped to at least 1 so a misconfiguration cannot spin.
nominalToMicros :: NominalDiffTime -> Int
nominalToMicros d = max 1 (round (realToFrac d * 1e6 :: Double))

nominalToNanos :: NominalDiffTime -> Word64
nominalToNanos d = round (realToFrac d * 1e9 :: Double)

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
    outputCapacityInt = max 1 (fromIntegral outputCapacity)

    acquire = do
      stateVar <- newTVarIO (emptyBatcherState, Seq.empty)
      doneVar <- newTVarIO False

      let onArrival ing = do
            now <- getMonotonicTimeNSec
            emitStep stateVar outputCapacityInt (stepArrival cfg now ing)

          -- Consume the whole input, flush the remainder, then mark done.
          -- 'finally' guarantees doneVar is set even if the input stream throws,
          -- so the output stream below always reaches the drain point. The drain
          -- then observes this async with 'waitCatch' and rethrows any consumer
          -- failure instead of reporting clean completion.
          consumer =
            ( do
                Stream.fold Fold.drain (Stream.mapM onArrival input)
                emitStep stateVar outputCapacityInt stepFlush
            )
              `finally` atomically (writeTVar doneVar True)

          tickerLoop = do
            threadDelay tickMicros
            done <- readTVarIO doneVar
            if done
              then pure ()
              else do
                now <- getMonotonicTimeNSec
                emitStep stateVar outputCapacityInt (stepTick cfg now)
                tickerLoop

      consumerA <- async consumer
      tickerA <- async tickerLoop
      pure (stateVar, doneVar, consumerA, tickerA)

    release (_stateVar, _doneVar, consumerA, tickerA) = do
      cancel tickerA
      cancel consumerA

    consume (stateVar, doneVar, consumerA, _tickerA) = drainQueue consumerA stateVar doneVar

-- | Stream finished batches out of the bounded queue, ending when the consumer
-- has flushed everything (doneVar), the queue has drained, and the consumer
-- async is known to have completed successfully.
drainQueue ::
  Async () ->
  TVar (BatcherState es msg, Seq (ReadyBatch es msg)) ->
  TVar Bool ->
  Stream IO (ReadyBatch es msg)
drainQueue consumerA stateVar doneVar = Stream.unfoldrM step ()
  where
    step _ = do
      drainStep <-
        atomically $ do
          (state, pending) <- readTVar stateVar
          case Seq.viewl pending of
            rb Seq.:< rest -> do
              writeTVar stateVar (state, rest)
              pure (DrainReady rb)
            Seq.EmptyL -> do
              done <- readTVar doneVar
              if done
                then pure DrainDone
                else retry
      case drainStep of
        DrainReady rb -> pure (Just (rb, ()))
        DrainDone ->
          waitCatch consumerA >>= \case
            Left ex -> throwIO ex
            Right () -> pure Nothing
