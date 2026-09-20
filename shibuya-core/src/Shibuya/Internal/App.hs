-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
module Shibuya.Internal.App
  ( QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle (..),
    OwnershipFailure (..),
    acquireOwned,
  )
where

import Control.Concurrent.STM (TMVar, TVar)
import Data.Map.Strict (Map)
import Effectful (Eff, IOE, (:>))
import Effectful.Exception qualified as Exception
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch (BatchConfig, BatchHandler)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Master (Master)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import UnliftIO (SomeException)

-- | Failure while acquiring an owner or while transferring resources into an
-- acquired owner's custody. Kept in this internal module so tests can inject a
-- deterministic cancellation barrier into the exact primitive used by
-- 'Shibuya.App.runApp'.
data OwnershipFailure
  = OwnerAcquisitionFailed !SomeException
  | OwnedActionFailed !SomeException !(Maybe SomeException)
  deriving stock (Show)

-- | Acquire an owner under masking, restore interruptibility while acquiring
-- the resources it will own, and clean the owner up before reporting any
-- synchronous or asynchronous failure from that action.
acquireOwned ::
  (IOE :> es) =>
  Eff es owner ->
  (owner -> Eff es ()) ->
  (owner -> Eff es value) ->
  Eff es (Either OwnershipFailure value)
acquireOwned acquireOwner releaseOwner acquireResources =
  Exception.mask $ \restore -> do
    ownerResult <- Exception.try @SomeException acquireOwner
    case ownerResult of
      Left failure -> pure $ Left $ OwnerAcquisitionFailed failure
      Right owner -> do
        resourceResult <- Exception.try @SomeException $ restore $ acquireResources owner
        case resourceResult of
          Right value -> pure $ Right value
          Left failure -> do
            cleanupResult <- Exception.try @SomeException $ releaseOwner owner
            pure $
              Left $
                OwnedActionFailed
                  failure
                  (either Just (const Nothing) cleanupResult)

-- | A queue processor pairs an adapter with a handler. The message type is
-- existentially hidden, allowing heterogeneous queues in one @runApp@ call.
--
-- @QueueProcessor@ processes one message at a time; @BatchingProcessor@ groups
-- messages into batches (see "Shibuya.Batch") and runs a batch handler over each.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: OrderingPolicy,
      concurrency :: Concurrency
    } ->
    QueueProcessor es
  BatchingProcessor ::
    { adapter :: Adapter es msg,
      batchHandler :: BatchHandler es msg,
      batchConfig :: BatchConfig es msg,
      ordering :: OrderingPolicy,
      concurrency :: Concurrency
    } ->
    QueueProcessor es

-- | Convenience constructor with default policies (Unordered + Serial).
-- Provides backward compatibility with existing code.
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
mkProcessor adapter handler = QueueProcessor adapter handler Unordered Serial

-- | Convenience constructor for a batching processor with safe default policies
-- (Unordered ordering + Serial concurrency, i.e. one batch at a time).
mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
mkBatchProcessor adapter batchHandler batchConfig =
  BatchingProcessor adapter batchHandler batchConfig Unordered Serial

-- | Handle for a running multi-queue application.
-- Provides introspection and control over all processors.
data AppHandle es = AppHandle
  { -- | The master coordinator
    master :: !Master,
    -- | Map of processor IDs to their handles
    processors :: !(Map ProcessorId (SupervisedProcessor, QueueProcessor es)),
    -- | Coordinates repeated and concurrent graceful-stop calls. The first
    -- caller performs shutdown; every caller observes the same terminal result.
    shutdownStarted :: !(TVar Bool),
    shutdownResult :: !(TMVar (Either SomeException Bool))
  }
