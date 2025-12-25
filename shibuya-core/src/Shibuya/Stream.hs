-- | Stream utilities for adapters.
-- Common stream transformations for use with adapters.
module Shibuya.Stream
  ( -- * Stream Sources
    pollingStream,

    -- * Transformations
    batchStream,
    filterStream,
  )
where

import Control.Concurrent (threadDelay)
import Effectful (Eff, IOE, liftIO, (:>))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Create a polling stream from a poll action.
-- Polls at the given interval, yielding messages when available.
pollingStream ::
  (IOE :> es) =>
  -- | Poll interval in microseconds
  Int ->
  -- | Poll action
  Eff es (Maybe msg) ->
  Stream (Eff es) msg
pollingStream interval poll =
  Stream.catMaybes $
    Stream.repeatM $ do
      mmsg <- poll
      case mmsg of
        Nothing -> liftIO (threadDelay interval) >> pure Nothing
        Just msg -> pure (Just msg)

-- | Batch messages into chunks.
batchStream :: (Monad m) => Int -> Stream m msg -> Stream m [msg]
batchStream n = Stream.foldMany (Fold.take n Fold.toList)

-- | Filter messages.
filterStream :: (Monad m) => (msg -> Bool) -> Stream m msg -> Stream m msg
filterStream = Stream.filter
