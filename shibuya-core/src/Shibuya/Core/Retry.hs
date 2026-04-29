-- | Exponential backoff policy and pure evaluator.
--
-- Handlers compute a 'RetryDelay' from a 'BackoffPolicy' and the current
-- delivery 'Attempt'. The pure evaluator takes a jitter sample in @[0,1)@
-- and is suitable for property tests.
module Shibuya.Core.Retry
  ( -- * Policy
    BackoffPolicy (..),
    Jitter (..),
    defaultBackoffPolicy,

    -- * Pure evaluator
    exponentialBackoffPure,

    -- * Effectful evaluator
    exponentialBackoff,

    -- * Handler convenience
    retryWithBackoff,
  )
where

import Data.Maybe (fromMaybe)
import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds, secondsToNominalDiffTime)
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import System.Random qualified as Random

-- | Strategy for adding randomness to backoff delays.
-- Jitter prevents thundering herds when many messages fail simultaneously.
--
-- See <https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/>.
data Jitter
  = -- | No randomness; delay is deterministic.
    NoJitter
  | -- | Delay is uniform in @[0, baseExp]@ where @baseExp@ is
    -- @min maxDelay (base * factor^attempt)@.
    FullJitter
  | -- | Delay is @baseExp / 2 + uniform(0, baseExp / 2)@.
    EqualJitter
  deriving stock (Eq, Show, Generic)

-- | Configuration for exponential backoff with optional jitter.
data BackoffPolicy = BackoffPolicy
  { -- | Base delay applied at attempt 0 (before jitter).
    base :: !NominalDiffTime,
    -- | Multiplicative growth factor between attempts. Typically 2.0.
    factor :: !Double,
    -- | Upper bound on the computed delay before jitter.
    -- Prevents arbitrarily long retries far in the future.
    maxDelay :: !NominalDiffTime,
    -- | Jitter strategy.
    jitter :: !Jitter
  }
  deriving stock (Eq, Show, Generic)

-- | Sensible defaults: 1 s base, factor 2, max 5 min, full jitter.
--
-- This matches AWS's published recommendation. With these defaults:
--
-- - Attempt 0: random delay in [0, 1) s
-- - Attempt 1: random delay in [0, 2) s
-- - Attempt 2: random delay in [0, 4) s
-- - ...
-- - Attempt 8 onwards: random delay in [0, 256) s, capped at [0, 300) s
defaultBackoffPolicy :: BackoffPolicy
defaultBackoffPolicy =
  BackoffPolicy
    { base = 1,
      factor = 2.0,
      maxDelay = 300,
      jitter = FullJitter
    }

-- | Compute a retry delay from a policy, an attempt count, and a jitter
-- sample in @[0, 1)@.
--
-- The sample is consumed only when the policy's 'jitter' is not 'NoJitter';
-- callers passing @0.0@ to a 'NoJitter' policy will see deterministic output.
exponentialBackoffPure ::
  BackoffPolicy ->
  Attempt ->
  -- | Jitter sample in @[0, 1)@. Ignored when 'jitter' = 'NoJitter'.
  Double ->
  RetryDelay
exponentialBackoffPure policy (Attempt n) sample =
  RetryDelay (secondsToNominalDiffTime (realToFrac jittered))
  where
    baseSec :: Double
    baseSec = realToFrac (nominalDiffTimeToSeconds policy.base)

    maxSec :: Double
    maxSec = realToFrac (nominalDiffTimeToSeconds policy.maxDelay)

    baseExp :: Double
    baseExp = min maxSec (baseSec * policy.factor ** fromIntegral n)

    clampedSample :: Double
    clampedSample = max 0 (min 0.999999 sample)

    jittered :: Double
    jittered = case policy.jitter of
      NoJitter -> baseExp
      FullJitter -> baseExp * clampedSample
      EqualJitter -> baseExp / 2 + (baseExp / 2) * clampedSample

-- | Compute a retry delay by sampling jitter from 'IO'.
--
-- Equivalent to 'exponentialBackoffPure' with a fresh sample drawn via
-- 'System.Random.randomRIO' on each call.
exponentialBackoff ::
  (IOE :> es) =>
  BackoffPolicy ->
  Attempt ->
  Eff es RetryDelay
exponentialBackoff policy attempt = do
  sample <- liftIO (Random.randomRIO (0.0 :: Double, 1.0))
  pure (exponentialBackoffPure policy attempt sample)

-- | One-line helper for the common case: read 'envelope.attempt', compute a
-- backoff delay, and return 'AckRetry'.
--
-- Treats 'Nothing' attempt as @'Attempt' 0@ (first delivery), so handlers
-- consuming envelopes from adapters that do not track redeliveries still
-- get a sensible base-delay retry.
retryWithBackoff ::
  (IOE :> es) =>
  BackoffPolicy ->
  Envelope msg ->
  Eff es AckDecision
retryWithBackoff policy envelope = do
  let attempt = fromMaybe (Attempt 0) envelope.attempt
  delay <- exponentialBackoff policy attempt
  pure (AckRetry delay)
