-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
module Shibuya.Internal.App
  ( QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle (..),
  )
where

import Data.Map.Strict (Map)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch (BatchConfig, BatchHandler)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Master (Master)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor)
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Prelude hiding (Ordering)

-- | A queue processor pairs an adapter with a handler. The message type is
-- existentially hidden, allowing heterogeneous queues in one 'runApp' call.
--
-- 'QueueProcessor' processes one message at a time; 'BatchingProcessor' groups
-- messages into batches (see "Shibuya.Batch") and runs a 'BatchHandler' over each.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es
  BatchingProcessor ::
    { adapter :: Adapter es msg,
      batchHandler :: BatchHandler es msg,
      batchConfig :: BatchConfig es msg,
      ordering :: Ordering,
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
    processors :: !(Map ProcessorId (SupervisedProcessor, QueueProcessor es))
  }
