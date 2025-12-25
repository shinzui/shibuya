-- | Adapter API - library-author facing.
-- Adapters bridge external systems to the framework.
-- Adapter owns queue semantics; runner never touches offsets directly.
module Shibuya.Adapter
  ( Adapter (..),
  )
where

import Data.Text (Text)
import Effectful (Eff)
import Shibuya.Core.Ingested (Ingested)
import Streamly.Data.Stream (Stream)

-- | Queue adapter interface.
-- Provides a stream of ingested messages and shutdown capability.
data Adapter es msg = Adapter
  { -- | Name for logging/observability
    adapterName :: !Text,
    -- | Stream of leased messages
    source :: Stream (Eff es) (Ingested es msg),
    -- | Stop polling, release resources
    shutdown :: Eff es ()
  }
