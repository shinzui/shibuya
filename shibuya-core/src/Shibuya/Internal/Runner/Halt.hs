-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Halt exception for processor termination.
-- Thrown when a handler returns AckHalt to stop processing.
module Shibuya.Internal.Runner.Halt
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
