-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Halt exception for processor termination.
-- Thrown when a handler returns AckHalt to stop processing.
module Shibuya.Internal.Runner.Halt
  ( ProcessorHalt (..),
    ProcessorFailure (..),
    ProcessorExit (..),
    ProcessorSignal,
    newProcessorSignal,
    readProcessorExit,
    requestProcessorExit,
    throwProcessorExit,
  )
where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (Exception)
import Shibuya.Core.Ack (HaltReason)
import Shibuya.Core.Types (MessageId)
import Shibuya.Prelude
import UnliftIO (throwIO)

-- | Exception thrown when processing should halt.
-- The supervisor catches this to handle graceful shutdown.
data ProcessorHalt = ProcessorHalt
  { reason :: !HaltReason
  }
  deriving stock (Show, Generic)

instance Exception ProcessorHalt

-- | An infrastructure failure that must remain distinguishable from a handler's
-- deliberate 'AckHalt'. The optional message identity is retained when the
-- failure occurred while finalizing a delivery.
data ProcessorFailure = ProcessorFailure !Text !(Maybe MessageId)
  deriving stock (Show, Generic)

instance Exception ProcessorFailure

-- | The first terminal request observed by a processor. Infrastructure failure
-- takes precedence over a graceful halt if concurrent work reports both.
data ProcessorExit
  = ProcessorHalted !HaltReason
  | ProcessorFailed !Text !(Maybe MessageId)
  deriving stock (Eq, Show, Generic)

type ProcessorSignal = TVar (Maybe ProcessorExit)

newProcessorSignal :: IO ProcessorSignal
newProcessorSignal = newTVarIO Nothing

readProcessorExit :: ProcessorSignal -> IO (Maybe ProcessorExit)
readProcessorExit = readTVarIO

requestProcessorExit :: ProcessorSignal -> ProcessorExit -> IO ()
requestProcessorExit signal requested =
  atomically $
    modifyTVar' signal $ \current ->
      case (current, requested) of
        (Just ProcessorFailed {}, _) -> current
        (_, ProcessorFailed {}) -> Just requested
        (Nothing, _) -> Just requested
        (Just ProcessorHalted {}, ProcessorHalted {}) -> current

throwProcessorExit :: ProcessorExit -> IO a
throwProcessorExit (ProcessorHalted reason) = throwIO (ProcessorHalt reason)
throwProcessorExit (ProcessorFailed failure messageId) =
  throwIO (ProcessorFailure failure messageId)
