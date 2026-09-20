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
    isProcessorStopping,
    readProcessorExit,
    readProcessorExitSTM,
    requestProcessorExit,
    throwProcessorExit,
  )
where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (Exception, mask_)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
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

-- | A cheap hot-path stop observation paired with an STM wake source. The
-- 'IORef' preserves the pre-existing per-item cost, while the 'TVar' is read by
-- an empty-inbox transaction so a terminal request wakes it immediately.
data ProcessorSignal = ProcessorSignal
  { stopping :: !(IORef Bool),
    terminalExit :: !(TVar (Maybe ProcessorExit))
  }

newProcessorSignal :: IO ProcessorSignal
newProcessorSignal = ProcessorSignal <$> newIORef False <*> newTVarIO Nothing

isProcessorStopping :: ProcessorSignal -> IO Bool
isProcessorStopping = readIORef . (.stopping)

readProcessorExit :: ProcessorSignal -> IO (Maybe ProcessorExit)
readProcessorExit = readTVarIO . (.terminalExit)

readProcessorExitSTM :: ProcessorSignal -> STM (Maybe ProcessorExit)
readProcessorExitSTM = readTVar . (.terminalExit)

requestProcessorExit :: ProcessorSignal -> ProcessorExit -> IO ()
requestProcessorExit signal requested =
  -- Publish the cheap stop observation before the STM wakeup. Masking prevents
  -- cancellation from leaving only the IORef set; this path runs once per
  -- terminal request, not once per message.
  mask_ $ do
    atomicWriteIORef signal.stopping True
    atomically $
      modifyTVar' signal.terminalExit $ \current ->
        case (current, requested) of
          (Just ProcessorFailed {}, _) -> current
          (_, ProcessorFailed {}) -> Just requested
          (Nothing, _) -> Just requested
          (Just ProcessorHalted {}, ProcessorHalted {}) -> current

throwProcessorExit :: ProcessorExit -> IO a
throwProcessorExit (ProcessorHalted reason) = throwIO (ProcessorHalt reason)
throwProcessorExit (ProcessorFailed failure messageId) =
  throwIO (ProcessorFailure failure messageId)
