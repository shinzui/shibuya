-- | Runner configuration.
-- User-facing configuration combining adapter, handler, and policies.
module Shibuya.Runner
  ( RunnerConfig (..),
    defaultRunnerConfig,
  )
where

import Shibuya.Adapter (Adapter)
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Prelude hiding (Ordering)

-- | Complete runner configuration.
data RunnerConfig es msg = RunnerConfig
  { -- | Queue adapter to use
    adapter :: !(Adapter es msg),
    -- | Message handler
    handler :: !(Handler es msg),
    -- | Ordering guarantees
    ordering :: !Ordering,
    -- | Concurrency mode
    concurrency :: !Concurrency,
    -- | Bounded inbox size for backpressure
    inboxSize :: !Int
  }

-- | Default configuration with sensible defaults.
-- Uses Unordered, Serial, inbox size 100.
defaultRunnerConfig :: Adapter es msg -> Handler es msg -> RunnerConfig es msg
defaultRunnerConfig adpt hdlr =
  RunnerConfig
    { adapter = adpt,
      handler = hdlr,
      ordering = Unordered,
      concurrency = Serial,
      inboxSize = 100
    }
