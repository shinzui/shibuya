-- | Lease types for temporary message ownership.
-- Lease exists only to model temporary ownership (SQS visibility timeout, DB locks).
-- Kafka adapters won't use this; SQS/Redis/DB queues will.
module Shibuya.Core.Lease
  ( Lease (..),
  )
where

import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff)

-- | Optional capability for sources with visibility/ownership.
-- Allows handlers to extend the lease if processing takes longer than expected.
data Lease es = Lease
  { -- | Identifier for the lease
    leaseId :: !Text,
    -- | Extend the lease by the given duration
    leaseExtend :: NominalDiffTime -> Eff es ()
  }
