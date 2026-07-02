-- | Bounded FIFO scheduler for work keyed by an optional partition key.
module Shibuya.Runner.KeyedScheduler
  ( runKeyedScheduler,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Unique (Unique, newUnique)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import UnliftIO (Async, SomeException, async, cancel, catchAny, finally, throwIO, withAsync)

-- | Run every item in a stream through the worker action, at most
-- @maxConcurrency@ at a time. Items with the same @Just key@ run strictly in
-- stream order; @Nothing@ items have no mutual ordering constraint. The pending
-- buffer is bounded and blocks the reader when full, preserving upstream
-- backpressure.
runKeyedScheduler ::
  (Ord key) =>
  Int ->
  Int ->
  (item -> Maybe key) ->
  (item -> IO ()) ->
  Stream.Stream IO item ->
  IO ()
runKeyedScheduler requestedConcurrency requestedPendingLimit itemKey itemAction itemStream = do
  scheduler <- newTVarIO emptyKeyedSchedulerState
  workers <- newTVarIO (Map.empty :: Map.Map Unique (Async ()))
  let maxConcurrency = max 1 requestedConcurrency
      pendingLimit = max 1 requestedPendingLimit
      cancelWorkers = do
        liveWorkers <- readTVarIO workers
        traverse_ cancel (Map.elems liveWorkers)

      reader =
        ( do
            Stream.fold Fold.drain $
              Stream.mapM (enqueueItem pendingLimit scheduler) itemStream
            atomically $ markInputDone scheduler Nothing
        )
          `catchAny` \ex ->
            atomically $ markInputDone scheduler (Just ex)

      loop = do
        step <- atomically $ nextSchedulerStep maxConcurrency itemKey scheduler
        case step of
          SchedulerDone Nothing -> pure ()
          SchedulerDone (Just ex) -> throwIO ex
          StartItem item -> do
            workerId <- newUnique
            startGate <- newEmptyMVar
            worker <- async $ do
              takeMVar startGate
              runWorker scheduler workers workerId itemKey itemAction item
            atomically $ modifyTVar' workers (Map.insert workerId worker)
            putMVar startGate ()
            loop

  withAsync reader $ \_reader ->
    loop `finally` cancelWorkers

data KeyedSchedulerState key item = KeyedSchedulerState
  { inputDone :: !Bool,
    activeKeys :: !(Set.Set key),
    running :: !Int,
    pending :: !(Seq item),
    firstFailure :: !(Maybe SomeException)
  }

data SchedulerStep item
  = StartItem !item
  | SchedulerDone !(Maybe SomeException)

emptyKeyedSchedulerState :: KeyedSchedulerState key item
emptyKeyedSchedulerState =
  KeyedSchedulerState
    { inputDone = False,
      activeKeys = Set.empty,
      running = 0,
      pending = Seq.empty,
      firstFailure = Nothing
    }

runWorker ::
  (Ord key) =>
  TVar (KeyedSchedulerState key item) ->
  TVar (Map.Map Unique (Async ())) ->
  Unique ->
  (item -> Maybe key) ->
  (item -> IO ()) ->
  item ->
  IO ()
runWorker scheduler workers workerId itemKey itemAction item = do
  resultRef <- newIORef Nothing
  let runItem =
        (itemAction item >> pure Nothing)
          `catchAny` (pure . Just)
          >>= writeIORef resultRef
      cleanup = do
        result <- readIORef resultRef
        atomically $ finishItem scheduler itemKey item result
        atomically $ modifyTVar' workers (Map.delete workerId)
  runItem `finally` cleanup

enqueueItem ::
  Int ->
  TVar (KeyedSchedulerState key item) ->
  item ->
  IO ()
enqueueItem pendingLimit scheduler item =
  atomically $ do
    s <- readTVar scheduler
    if Seq.length s.pending >= pendingLimit
      then retry
      else writeTVar scheduler s {pending = s.pending Seq.|> item}

markInputDone ::
  TVar (KeyedSchedulerState key item) ->
  Maybe SomeException ->
  STM ()
markInputDone scheduler failure =
  modifyTVar' scheduler $ \s ->
    s
      { inputDone = True,
        firstFailure = s.firstFailure <|> failure
      }

nextSchedulerStep ::
  (Ord key) =>
  Int ->
  (item -> Maybe key) ->
  TVar (KeyedSchedulerState key item) ->
  STM (SchedulerStep item)
nextSchedulerStep maxConcurrency itemKey scheduler = do
  s <- readTVar scheduler
  case (s.running < maxConcurrency, popStartable itemKey s.activeKeys s.pending) of
    (True, Just (item, rest)) -> do
      writeTVar
        scheduler
        s
          { activeKeys = maybe s.activeKeys (`Set.insert` s.activeKeys) (itemKey item),
            running = s.running + 1,
            pending = rest
          }
      pure (StartItem item)
    _
      | s.inputDone && Seq.null s.pending && s.running == 0 ->
          pure (SchedulerDone s.firstFailure)
      | otherwise ->
          retry

finishItem ::
  (Ord key) =>
  TVar (KeyedSchedulerState key item) ->
  (item -> Maybe key) ->
  item ->
  Maybe SomeException ->
  STM ()
finishItem scheduler itemKey item failure =
  modifyTVar' scheduler $ \s ->
    s
      { activeKeys = maybe s.activeKeys (`Set.delete` s.activeKeys) (itemKey item),
        running = s.running - 1,
        firstFailure = s.firstFailure <|> failure
      }

popStartable ::
  (Ord key) =>
  (item -> Maybe key) ->
  Set.Set key ->
  Seq item ->
  Maybe (item, Seq item)
popStartable itemKey active = go Seq.empty
  where
    go skipped items =
      case Seq.viewl items of
        Seq.EmptyL ->
          Nothing
        item Seq.:< rest ->
          case itemKey item of
            Just key
              | key `Set.member` active ->
                  go (skipped Seq.|> item) rest
            _ ->
              Just (item, skipped <> rest)
