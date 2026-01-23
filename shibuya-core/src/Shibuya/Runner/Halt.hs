-- | Halt exception for processor termination.
-- Thrown when a handler returns AckHalt to stop processing.
module Shibuya.Runner.Halt
  ( ProcessorHalt (..),
  )
where

import Control.Exception (Exception)
import Shibuya.Core.Ack (HaltReason)
import Shibuya.Prelude

-- | Exception thrown when processing should halt.
-- The supervisor catches this to handle graceful shutdown.
data ProcessorHalt = ProcessorHalt
  { reason :: !HaltReason
  }
  deriving stock (Show, Generic)

instance Exception ProcessorHalt
